defmodule ASM.InferenceEndpoint do
  @moduledoc """
  Publishes CLI-backed ASM providers as endpoint-shaped inference targets.
  """

  alias ASM.InferenceEndpoint.BackendManifest
  alias ASM.InferenceEndpoint.Compatibility
  alias ASM.InferenceEndpoint.CompatibilityResult
  alias ASM.InferenceEndpoint.ConsumerManifest
  alias ASM.InferenceEndpoint.EndpointDescriptor
  alias ASM.InferenceEndpoint.LeaseStore
  alias ASM.InferenceEndpoint.Server
  alias ASM.Provider

  @type ensure_result ::
          {:ok, EndpointDescriptor.t(), CompatibilityResult.t()}
          | {:error, {:incompatible, CompatibilityResult.t()}}
          | {:error, term()}

  @spec consumer_manifest() :: ConsumerManifest.t()
  def consumer_manifest do
    ConsumerManifest.new!(
      consumer: :asm_openai_endpoint,
      accepted_runtime_kinds: [:task],
      accepted_management_modes: [:jido_managed],
      accepted_protocols: [:openai_chat_completions],
      required_capabilities: %{},
      optional_capabilities: %{streaming?: true},
      constraints: %{target_class: :cli_endpoint},
      metadata: %{source_runtime: :agent_session_manager}
    )
  end

  @spec ensure_endpoint(map() | keyword(), map() | keyword() | struct(), map() | keyword()) ::
          ensure_result()
  def ensure_endpoint(request, consumer_manifest, context)
      when (is_map(request) or is_list(request)) and
             (is_map(context) or is_list(context)) do
    request = normalize_map(request)
    context = normalize_map(context)

    with {:ok, consumer_manifest} <- normalize_consumer_manifest(consumer_manifest),
         {:ok, provider} <- request_provider(request),
         {:ok, model_identity} <- request_model_identity(request),
         publication <- publication(provider),
         backend_manifest <- backend_manifest(provider, publication),
         compatibility <- Compatibility.resolve(backend_manifest, consumer_manifest, request),
         true <- compatibility.compatible? || {:error, {:incompatible, compatibility}},
         {:ok, base_url_root} <- Server.base_url_root(),
         lease <-
           build_lease(
             provider,
             model_identity,
             publication,
             backend_manifest,
             context,
             base_url_root
           ),
         :ok <- LeaseStore.put(lease),
         endpoint <- endpoint_descriptor(lease) do
      {:ok, endpoint, compatibility}
    end
  end

  def ensure_endpoint(request, _consumer_manifest, _context)
      when not (is_map(request) or is_list(request)) do
    {:error, {:invalid_request, request}}
  end

  @spec release_endpoint(String.t() | map()) :: :ok
  def release_endpoint(%{lease_ref: lease_ref}) when is_binary(lease_ref),
    do: release_endpoint(lease_ref)

  def release_endpoint(lease_ref) when is_binary(lease_ref), do: LeaseStore.delete(lease_ref)
  def release_endpoint(_other), do: :ok

  defp normalize_consumer_manifest(%ConsumerManifest{} = manifest), do: {:ok, manifest}

  defp normalize_consumer_manifest(%{} = manifest) do
    manifest
    |> normalize_map()
    |> ConsumerManifest.new()
  end

  defp normalize_consumer_manifest(manifest) when is_list(manifest) do
    manifest
    |> Map.new()
    |> ConsumerManifest.new()
  end

  defp normalize_consumer_manifest(other), do: {:error, {:invalid_consumer_manifest, other}}

  defp request_provider(request) do
    model_preference = value(request, :model_preference, %{})
    provider_hint = value(model_preference, :provider)

    case Provider.resolve(provider_hint) do
      {:ok, %Provider{} = provider} ->
        {:ok, provider.name}

      _other ->
        {:error, {:unsupported_provider, provider_hint}}
    end
  end

  defp request_model_identity(request) do
    model_preference = value(request, :model_preference, %{})

    case value(model_preference, :id, value(model_preference, :model)) do
      model when is_binary(model) and model != "" -> {:ok, model}
      other -> {:error, {:missing_model_identity, other}}
    end
  end

  defp publication(provider) when provider in [:amp, :claude, :codex, :gemini] do
    capabilities =
      provider
      |> Provider.resolve!()
      |> Map.fetch!(:core_profile)
      |> Kernel.apply(:capabilities, [])

    %{
      provider: provider,
      cli_completion_v1: completion_capable?(capabilities),
      cli_streaming_v1: :streaming in capabilities,
      cli_agent_v2: agent_capable?(provider, capabilities),
      common_surface_only?: common_surface_only?(provider),
      derivation: %{
        cli_completion_v1: :prompt_driven_cli_profile,
        cli_streaming_v1: :streaming_profile_capability,
        cli_agent_v2: agent_capability_derivation(provider)
      },
      profile_capabilities: capabilities
    }
  end

  defp completion_capable?(capabilities) when is_list(capabilities) do
    Enum.any?(
      capabilities,
      &(&1 in [:streaming, :reasoning, :thinking, :tools, :extensions, :mcp])
    )
  end

  defp agent_capable?(provider, capabilities)
       when provider in [:claude, :codex] and is_list(capabilities) do
    Enum.all?([:streaming, :tools], &(&1 in capabilities))
  end

  defp agent_capable?(_provider, _capabilities), do: false

  defp common_surface_only?(provider), do: provider in [:amp, :gemini]

  defp agent_capability_derivation(provider) when provider in [:claude, :codex],
    do: :provider_native_extension_surface

  defp agent_capability_derivation(_provider), do: :common_surface_only_provider

  defp backend_manifest(provider, publication) do
    BackendManifest.new!(
      backend: :asm_inference_endpoint,
      runtime_kind: :task,
      management_modes: [:jido_managed],
      startup_kind: :spawned,
      protocols: [:openai_chat_completions],
      capabilities: %{
        streaming?: publication.cli_streaming_v1,
        tool_calling?: false,
        embeddings?: :unknown
      },
      supported_surfaces: [:local_subprocess, :ssh_exec, :guest_bridge],
      resource_profile: %{profile: "cli_session"},
      metadata: %{
        family: :asm,
        provider: provider,
        common_surface_only?: publication.common_surface_only?,
        published_capabilities: %{
          cli_completion_v1: publication.cli_completion_v1,
          cli_streaming_v1: publication.cli_streaming_v1,
          cli_agent_v2: publication.cli_agent_v2
        },
        profile_capabilities: publication.profile_capabilities,
        derivation: publication.derivation
      }
    )
  end

  defp build_lease(
         provider,
         model_identity,
         publication,
         backend_manifest,
         context,
         base_url_root
       ) do
    lease_ref = "lease_" <> ASM.Event.generate_id()
    endpoint_id = "endpoint_" <> ASM.Event.generate_id()
    auth_token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    endpoint_base_url = "#{base_url_root}/leases/#{lease_ref}/v1"
    health_ref = "#{base_url_root}/leases/#{lease_ref}/health"

    %{
      lease_ref: lease_ref,
      endpoint_id: endpoint_id,
      auth_token: auth_token,
      provider: provider,
      model_identity: model_identity,
      boundary_ref: value(context, :boundary_ref),
      publication: publication,
      backend_manifest: backend_manifest,
      base_url: endpoint_base_url,
      health_ref: health_ref,
      source_runtime_ref: lease_ref,
      endpoint_capabilities: %{
        streaming?: publication.cli_streaming_v1,
        tool_calling?: false
      }
    }
  end

  defp endpoint_descriptor(lease) do
    EndpointDescriptor.new!(
      endpoint_id: lease.endpoint_id,
      runtime_kind: :task,
      management_mode: :jido_managed,
      target_class: :cli_endpoint,
      protocol: :openai_chat_completions,
      base_url: lease.base_url,
      headers: %{"authorization" => "Bearer #{lease.auth_token}"},
      provider_identity: lease.provider,
      model_identity: lease.model_identity,
      source_runtime: :agent_session_manager,
      source_runtime_ref: lease.source_runtime_ref,
      lease_ref: lease.lease_ref,
      health_ref: lease.health_ref,
      boundary_ref: lease.boundary_ref,
      capabilities: lease.endpoint_capabilities,
      metadata: %{
        publication: lease.publication,
        backend_manifest: Map.from_struct(lease.backend_manifest)
      }
    )
  end

  defp normalize_map(%_{} = value), do: value |> Map.from_struct() |> Map.new()
  defp normalize_map(%{} = value), do: Map.new(value)
  defp normalize_map(value) when is_list(value), do: Map.new(value)

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end

defmodule ASM.JidoHarness.Driver do
  @moduledoc """
  `Jido.Harness.RuntimeDriver` implementation backed by the ASM session runtime.

  The bridge keeps the Harness IR provider-neutral while projecting ASM's
  session lifecycle, event envelopes, and result reducers into the shared
  Session Control surface.
  """

  @behaviour Jido.Harness.RuntimeDriver

  alias ASM.{Event, Provider, Stream}
  alias ASM.JidoHarness.Normalizer

  alias Jido.Harness.{
    Error,
    ExecutionStatus,
    RunHandle,
    RunRequest,
    RuntimeDescriptor,
    SessionHandle
  }

  @supported_providers [:amp, :claude, :codex, :gemini, :shell]
  @asm_session_option_keys [
    :provider,
    :permission_mode,
    :provider_permission_mode,
    :cli_path,
    :cwd,
    :env,
    :args,
    :queue_limit,
    :overflow_policy,
    :subscriber_queue_warn,
    :subscriber_queue_limit,
    :approval_timeout_ms,
    :transport_timeout_ms,
    :transport_headless_timeout_ms,
    :max_stdout_buffer_bytes,
    :max_stderr_buffer_bytes,
    :max_concurrent_runs,
    :max_queued_runs,
    :debug,
    :driver,
    :driver_opts,
    :execution_mode,
    :stream_timeout_ms,
    :queue_timeout_ms,
    :transport_call_timeout_ms,
    :run_module,
    :run_module_opts,
    :tools,
    :tool_executor,
    :pipeline,
    :pipeline_ctx
  ]
  @asm_run_option_keys @asm_session_option_keys ++ [:run_id]

  @impl true
  def runtime_id, do: :asm

  @impl true
  def runtime_descriptor(opts \\ []) do
    requested_provider = Keyword.get(opts, :provider)
    provider = resolve_provider(requested_provider)

    RuntimeDescriptor.new!(%{
      runtime_id: :asm,
      provider: requested_provider && Normalizer.canonical_provider(requested_provider),
      label: descriptor_label(provider),
      session_mode: :external,
      streaming?: true,
      cancellation?: true,
      approvals?:
        supports?(provider, :supports_control, fn -> any_provider_supports?(:supports_control) end),
      cost?: true,
      subscribe?: false,
      resume?:
        supports?(provider, :supports_resume, fn -> any_provider_supports?(:supports_resume) end),
      metadata: descriptor_metadata(provider)
    })
  end

  @impl true
  def start_session(opts) when is_list(opts) do
    with {:ok, requested_provider, provider} <- fetch_provider(opts),
         {:ok, session_ref} <-
           ASM.start_session(start_session_opts(opts, provider, requested_provider)),
         session_id when is_binary(session_id) <- ASM.session_id(session_ref) do
      {:ok,
       SessionHandle.new!(%{
         session_id: session_id,
         runtime_id: :asm,
         provider: requested_provider,
         status: :ready,
         driver_ref: session_ref,
         metadata:
           %{}
           |> Map.put("asm_provider", Atom.to_string(provider.name))
           |> Map.put("display_name", provider.display_name)
       })}
    else
      {:error, _} = error ->
        error

      nil ->
        {:error, Error.execution_error("ASM did not return a session id", %{runtime_id: :asm})}
    end
  end

  @impl true
  def stop_session(%SessionHandle{driver_ref: session_ref}) when is_pid(session_ref) do
    ASM.stop_session(session_ref)
  end

  def stop_session(%SessionHandle{session_id: session_id}) when is_binary(session_id) do
    ASM.stop_session(session_id)
  end

  @impl true
  def stream_run(%SessionHandle{} = session, %RunRequest{} = request, opts) when is_list(opts) do
    with {:ok, provider} <- fetch_session_provider(session, opts) do
      run_id = Keyword.get_lazy(opts, :run_id, &Event.generate_id/0)
      asm_opts = stream_run_opts(request, provider, opts, run_id)

      stream =
        session
        |> session_ref!()
        |> ASM.stream(request.prompt, asm_opts)
        |> Elixir.Stream.map(&Normalizer.to_execution_event(&1, session))

      {:ok,
       RunHandle.new!(%{
         run_id: run_id,
         session_id: session.session_id,
         runtime_id: session.runtime_id,
         provider: session.provider,
         status: :running,
         started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         metadata: %{"transport" => provider.profile.transport_mode |> Atom.to_string()}
       }), stream}
    end
  rescue
    error in [ArgumentError] ->
      {:error,
       Error.execution_error("ASM stream bridge failed", %{error: Exception.message(error)})}
  end

  @impl true
  def run(%SessionHandle{} = session, %RunRequest{} = request, opts) when is_list(opts) do
    with {:ok, provider} <- fetch_session_provider(session, opts) do
      result =
        session
        |> session_ref!()
        |> ASM.stream(
          request.prompt,
          stream_run_opts(
            request,
            provider,
            opts,
            Keyword.get_lazy(opts, :run_id, &Event.generate_id/0)
          )
        )
        |> Stream.final_result()

      {:ok, Normalizer.to_execution_result(result, session)}
    end
  rescue
    error in [ArgumentError] ->
      {:error,
       Error.execution_error("ASM result bridge failed", %{error: Exception.message(error)})}
  end

  @impl true
  def cancel_run(%SessionHandle{} = session, %RunHandle{run_id: run_id}) do
    ASM.interrupt(session_ref!(session), run_id)
  end

  def cancel_run(%SessionHandle{} = session, run_id) when is_binary(run_id) do
    ASM.interrupt(session_ref!(session), run_id)
  end

  @impl true
  def session_status(%SessionHandle{} = session) do
    health = ASM.health(session_ref!(session))

    status =
      case health do
        :healthy -> :ready
        :degraded -> :degraded
        {:unhealthy, _reason} -> :stopped
      end

    message =
      case health do
        {:unhealthy, reason} -> inspect(reason)
        _ -> nil
      end

    {:ok,
     ExecutionStatus.new!(%{
       runtime_id: :asm,
       session_id: session.session_id,
       scope: :session,
       state: status,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
       message: message,
       details: %{"provider" => Atom.to_string(session.provider)}
     })}
  end

  @impl true
  def approve(%SessionHandle{} = session, approval_id, decision, _opts)
      when is_binary(approval_id) and decision in [:allow, :deny] do
    ASM.approve(session_ref!(session), approval_id, decision)
  end

  @impl true
  def cost(%SessionHandle{} = session) do
    {:ok, ASM.cost(session_ref!(session)) |> Normalizer.normalize() |> default_map()}
  end

  defp fetch_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, provider_name} when is_atom(provider_name) ->
        canonical = Normalizer.canonical_provider(provider_name)

        case Provider.resolve(canonical) do
          {:ok, provider} -> {:ok, canonical, provider}
          {:error, error} -> {:error, error}
        end

      _ ->
        {:error,
         Error.validation_error("provider is required for the ASM runtime bridge", %{
           field: :provider
         })}
    end
  end

  defp fetch_session_provider(%SessionHandle{provider: provider_name}, opts) do
    provider_name = provider_name || Keyword.get(opts, :provider)

    case provider_name do
      name when is_atom(name) ->
        case Provider.resolve(name) do
          {:ok, provider} -> {:ok, provider}
          {:error, error} -> {:error, error}
        end

      _ ->
        {:error,
         Error.validation_error("session handle is missing provider metadata", %{field: :provider})}
    end
  end

  defp resolve_provider(nil), do: nil

  defp resolve_provider(provider_name) do
    provider_name
    |> Normalizer.canonical_provider()
    |> Provider.resolve!()
  end

  defp descriptor_label(nil), do: "ASM"
  defp descriptor_label(provider), do: "#{provider.display_name} via ASM"

  defp descriptor_metadata(nil) do
    %{
      "supported_providers" => Enum.map(@supported_providers, &Atom.to_string/1)
    }
  end

  defp descriptor_metadata(provider) do
    %{
      "supported_providers" => Enum.map(@supported_providers, &Atom.to_string/1),
      "asm_provider" => Atom.to_string(provider.name),
      "display_name" => provider.display_name,
      "binary_names" => provider.binary_names,
      "env_var" => provider.env_var,
      "transport_mode" => Atom.to_string(provider.profile.transport_mode),
      "control_mode" => Atom.to_string(provider.profile.control_mode),
      "session_profile_mode" => Atom.to_string(provider.profile.session_mode)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp any_provider_supports?(field) do
    Enum.any?(@supported_providers, fn provider ->
      provider
      |> Provider.resolve!()
      |> Map.get(field)
    end)
  end

  defp supports?(nil, _field, fallback), do: fallback.()
  defp supports?(provider, field, _fallback), do: Map.get(provider, field)

  defp start_session_opts(opts, provider, requested_provider) do
    opts
    |> Keyword.put(:provider, requested_provider)
    |> Keyword.take(@asm_session_option_keys ++ Keyword.keys(provider.options_schema))
  end

  defp stream_run_opts(%RunRequest{} = request, provider, opts, run_id) do
    filtered_request_opts(request, provider)
    |> Keyword.merge(opts)
    |> Keyword.put(:run_id, run_id)
    |> Keyword.take(@asm_run_option_keys ++ Keyword.keys(provider.options_schema))
  end

  defp filtered_request_opts(%RunRequest{} = request, provider) do
    allowed_keys =
      provider.options_schema
      |> Keyword.keys()
      |> Kernel.++([:cwd])
      |> Enum.uniq()

    provider_opts =
      [
        cwd: request.cwd,
        model: request.model,
        max_turns: request.max_turns,
        system_prompt: request.system_prompt
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.take(allowed_keys)

    stream_opts =
      []
      |> maybe_put(:stream_timeout_ms, request.timeout_ms)

    provider_opts ++ stream_opts
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp session_ref!(%SessionHandle{driver_ref: session_ref}) when is_pid(session_ref),
    do: session_ref

  defp session_ref!(%SessionHandle{session_id: session_id}) when is_binary(session_id) do
    session_id
  end

  defp default_map(%{} = value), do: value
  defp default_map(_other), do: %{}
end

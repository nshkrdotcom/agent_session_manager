defmodule ASM.ProviderFeatures do
  @moduledoc """
  Public provider feature manifests for ASM.

  This module exposes two related surfaces:

  - provider-native permission mode metadata inherited from
    `CliSubprocessCore.ProviderFeatures`
  - ASM common features that are only supported by some providers, such as the
    common Ollama surface
  """

  alias ASM.{Error, Provider, ProviderRegistry}
  alias CliSubprocessCore.ProviderFeatures, as: CoreProviderFeatures

  @support_states [:common, :native, :sdk_local, :event_only, :unsupported, :planned]

  @type permission_manifest :: CoreProviderFeatures.permission_manifest()

  @type common_feature_manifest :: %{
          supported?: boolean(),
          common_surface: true,
          common_opts: [atom()],
          activation: map() | nil,
          model_strategy: atom() | nil,
          compatibility: map() | nil,
          notes: [String.t()]
        }

  @type manifest :: %{
          provider: Provider.provider_name(),
          permission_modes: %{optional(atom()) => permission_manifest()},
          common_features: %{optional(atom()) => common_feature_manifest()},
          lanes: %{optional(atom()) => lane_manifest()}
        }

  @type capability_manifest :: %{
          supported?: boolean(),
          lane: atom() | [atom()],
          provider_native?: boolean(),
          common_surface?: boolean(),
          support_state: :common | :native | :sdk_local | :event_only | :unsupported | :planned,
          asm_option_keys: [atom()],
          provider_native_option_keys: [atom()],
          event_kinds: [atom()],
          live_example: String.t() | nil,
          notes: [String.t()]
        }

  @type lane_manifest :: %{
          provider: Provider.provider_name(),
          lane: atom(),
          composition_mode: :common_surface_only | :native_extension,
          sdk_available?: boolean(),
          native_namespaces: [module()],
          capabilities: %{optional(atom()) => capability_manifest()}
        }

  @spec support_states() :: [atom()]
  def support_states, do: @support_states

  @spec manifest(Provider.t() | Provider.provider_name()) ::
          {:ok, manifest()} | {:error, Error.t()}
  def manifest(provider_or_name) do
    with {:ok, %Provider{} = provider} <- Provider.resolve(provider_or_name) do
      {:ok,
       %{
         provider: provider.name,
         permission_modes: core_permission_modes(provider.name),
         common_features: provider.feature_manifest,
         lanes: lane_manifests(provider.name)
       }}
    end
  end

  @spec manifest!(Provider.t() | Provider.provider_name()) :: manifest()
  def manifest!(provider_or_name) do
    case manifest(provider_or_name) do
      {:ok, manifest} ->
        manifest

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec permission_mode(Provider.t() | Provider.provider_name(), atom() | String.t()) ::
          {:ok, permission_manifest()} | {:error, Error.t()}
  def permission_mode(provider_or_name, mode) do
    with {:ok, %Provider{} = provider} <- Provider.resolve(provider_or_name) do
      case CoreProviderFeatures.permission_mode(provider.name, mode) do
        {:ok, manifest} ->
          {:ok, manifest}

        :error ->
          {:error,
           Error.new(
             :config_invalid,
             :config,
             "unknown permission mode #{inspect(mode)} for #{inspect(provider.name)}"
           )}
      end
    end
  end

  @spec permission_mode!(Provider.t() | Provider.provider_name(), atom() | String.t()) ::
          permission_manifest()
  def permission_mode!(provider_or_name, mode) do
    case permission_mode(provider_or_name, mode) do
      {:ok, manifest} ->
        manifest

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec common_feature(Provider.t() | Provider.provider_name(), atom()) ::
          {:ok, common_feature_manifest()} | {:error, Error.t()}
  def common_feature(provider_or_name, feature) when is_atom(feature) do
    with {:ok, manifest} <- manifest(provider_or_name) do
      case Map.fetch(manifest.common_features, feature) do
        {:ok, feature_manifest} ->
          {:ok, feature_manifest}

        :error ->
          {:error,
           Error.new(
             :config_invalid,
             :config,
             "unknown common feature #{inspect(feature)} for #{inspect(manifest.provider)}"
           )}
      end
    end
  end

  @spec common_feature!(Provider.t() | Provider.provider_name(), atom()) ::
          common_feature_manifest()
  def common_feature!(provider_or_name, feature) when is_atom(feature) do
    case common_feature(provider_or_name, feature) do
      {:ok, feature_manifest} ->
        feature_manifest

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec supports_common_feature?(Provider.t() | Provider.provider_name(), atom()) :: boolean()
  def supports_common_feature?(provider_or_name, feature) when is_atom(feature) do
    case common_feature(provider_or_name, feature) do
      {:ok, %{supported?: true}} -> true
      _other -> false
    end
  end

  @spec lane_manifest(Provider.t() | Provider.provider_name(), atom()) ::
          {:ok, lane_manifest()} | {:error, Error.t()}
  def lane_manifest(provider_or_name, lane) when is_atom(lane) do
    with {:ok, manifest} <- manifest(provider_or_name) do
      case Map.fetch(manifest.lanes, lane) do
        {:ok, lane_manifest} ->
          {:ok, lane_manifest}

        :error ->
          {:error,
           Error.new(
             :config_invalid,
             :provider,
             "unknown capability lane #{inspect(lane)} for #{inspect(manifest.provider)}"
           )}
      end
    end
  end

  @spec lane_manifest!(Provider.t() | Provider.provider_name(), atom()) :: lane_manifest()
  def lane_manifest!(provider_or_name, lane) when is_atom(lane) do
    case lane_manifest(provider_or_name, lane) do
      {:ok, manifest} ->
        manifest

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec capability(Provider.t() | Provider.provider_name(), atom(), atom()) ::
          {:ok, capability_manifest()} | {:error, Error.t()}
  def capability(provider_or_name, lane, capability) when is_atom(lane) and is_atom(capability) do
    with {:ok, lane_manifest} <- lane_manifest(provider_or_name, lane) do
      case Map.fetch(lane_manifest.capabilities, capability) do
        {:ok, capability_manifest} ->
          {:ok, capability_manifest}

        :error ->
          {:error,
           Error.new(
             :config_invalid,
             :provider,
             "unknown capability #{inspect(capability)} for #{inspect(lane_manifest.provider)} lane #{inspect(lane)}"
           )}
      end
    end
  end

  @spec require_capability(Provider.t() | Provider.provider_name(), atom(), atom()) ::
          :ok | {:error, Error.t()}
  def require_capability(provider_or_name, lane, capability)
      when is_atom(lane) and is_atom(capability) do
    with {:ok, provider} <- Provider.resolve(provider_or_name),
         {:ok, capability_manifest} <- capability(provider, lane, capability) do
      if capability_manifest.supported? do
        :ok
      else
        {:error,
         Error.new(
           :config_invalid,
           :provider,
           "capability #{inspect(capability)} is #{capability_manifest.support_state} for #{inspect(provider.name)} lane #{inspect(lane)}"
         )}
      end
    end
  end

  defp core_permission_modes(provider) when is_atom(provider) do
    provider
    |> CoreProviderFeatures.manifest!()
    |> Map.fetch!(:permission_modes)
  end

  defp lane_manifests(provider) do
    provider
    |> lane_ids()
    |> Enum.map(fn lane -> {lane, build_lane_manifest(provider, lane)} end)
    |> Map.new()
  end

  defp lane_ids(:codex), do: [:core, :sdk, :sdk_app_server]
  defp lane_ids(_provider), do: [:core, :sdk]

  defp build_lane_manifest(provider, lane) do
    native? = native_lane?(provider, lane)

    %{
      provider: provider,
      lane: lane,
      composition_mode: if(native?, do: :native_extension, else: :common_surface_only),
      sdk_available?: ProviderRegistry.sdk_available?(provider),
      native_namespaces: if(native?, do: native_namespaces(provider), else: []),
      capabilities: capability_map(provider, lane)
    }
  end

  defp native_lane?(:codex, :sdk_app_server), do: true
  defp native_lane?(:claude, :sdk), do: true
  defp native_lane?(_provider, _lane), do: false

  defp native_namespaces(:codex),
    do: [Module.concat(["ASM", "Extensions", "ProviderSDK", "Codex"])]

  defp native_namespaces(:claude),
    do: [Module.concat(["ASM", "Extensions", "ProviderSDK", "Claude"])]

  defp native_namespaces(_provider), do: []

  defp capability_map(:codex, :sdk_app_server) do
    %{
      app_server:
        capability_manifest(:native, :sdk_app_server,
          provider_native?: true,
          provider_native_option_keys: [:app_server],
          live_example: "mix run examples/live_codex_app_server_dynamic_tools.exs"
        ),
      host_tools:
        capability_manifest(:native, :sdk_app_server,
          provider_native?: true,
          asm_option_keys: [:host_tools, :tools],
          provider_native_option_keys: [:dynamic_tools],
          event_kinds: [
            :host_tool_requested,
            :host_tool_completed,
            :host_tool_failed,
            :host_tool_denied
          ],
          live_example: "mix run examples/live_codex_app_server_dynamic_tools.exs"
        ),
      session_resume:
        capability_manifest(:native, :sdk_app_server,
          provider_native?: true,
          asm_option_keys: [:continuation],
          provider_native_option_keys: [:thread_id]
        ),
      sandbox_policy:
        capability_manifest(:native, :sdk_app_server,
          provider_native?: true,
          provider_native_option_keys: [:sandbox_policy, :sandbox]
        ),
      approvals:
        capability_manifest(:native, :sdk_app_server,
          provider_native?: true,
          asm_option_keys: [:approval_timeout_ms],
          provider_native_option_keys: [:ask_for_approval, :approvals_reviewer],
          event_kinds: [:approval_requested, :approval_resolved]
        ),
      workspace_context:
        capability_manifest(:common, [:core, :sdk_app_server],
          common_surface?: true,
          asm_option_keys: [:cwd, :additional_directories]
        )
    }
  end

  defp capability_map(:codex, :core) do
    %{
      app_server: unsupported(:core),
      host_tools:
        capability_manifest(:event_only, :core,
          event_kinds: [:tool_use, :tool_result],
          notes: [
            "core exec can observe provider tool-use events but cannot answer host dynamic tools"
          ]
        ),
      session_resume: capability_manifest(:event_only, :core, asm_option_keys: [:continuation]),
      sandbox_policy:
        capability_manifest(:sdk_local, :core,
          provider_native?: true,
          provider_native_option_keys: [:sandbox_policy, :sandbox]
        ),
      approvals: capability_manifest(:event_only, :core, event_kinds: [:approval_requested]),
      workspace_context:
        capability_manifest(:common, :core, common_surface?: true, asm_option_keys: [:cwd])
    }
  end

  defp capability_map(:codex, :sdk), do: capability_map(:codex, :core)

  defp capability_map(:claude, :sdk) do
    %{
      app_server: unsupported(:sdk),
      host_tools:
        unsupported(:sdk,
          notes: [
            "Claude hooks and permission callbacks are native controls, not Codex dynamicTools"
          ]
        ),
      provider_control:
        capability_manifest(:native, :sdk,
          provider_native?: true,
          provider_native_option_keys: [:hooks, :permission_callbacks, :mcp]
        ),
      session_resume:
        capability_manifest(:common, :sdk,
          common_surface?: true,
          asm_option_keys: [:continuation]
        ),
      sandbox_policy:
        capability_manifest(:sdk_local, :sdk,
          provider_native?: true,
          provider_native_option_keys: [:permission_mode]
        ),
      approvals:
        capability_manifest(:native, :sdk,
          provider_native?: true,
          provider_native_option_keys: [:permission_callbacks],
          event_kinds: [:approval_requested, :approval_resolved]
        ),
      workspace_context:
        capability_manifest(:common, :sdk, common_surface?: true, asm_option_keys: [:cwd])
    }
  end

  defp capability_map(:claude, :core) do
    %{
      app_server: unsupported(:core),
      host_tools: capability_manifest(:event_only, :core, event_kinds: [:tool_use]),
      provider_control: unsupported(:core),
      session_resume:
        capability_manifest(:common, :core,
          common_surface?: true,
          asm_option_keys: [:continuation]
        ),
      sandbox_policy: unsupported(:core),
      approvals: capability_manifest(:event_only, :core, event_kinds: [:approval_requested]),
      workspace_context:
        capability_manifest(:common, :core, common_surface?: true, asm_option_keys: [:cwd])
    }
  end

  defp capability_map(:amp, lane) do
    %{
      app_server: unsupported(lane),
      host_tools: unsupported(lane),
      session_resume:
        capability_manifest(:common, lane,
          common_surface?: true,
          asm_option_keys: [:continuation]
        ),
      sandbox_policy: unsupported(lane),
      approvals:
        capability_manifest(:sdk_local, lane,
          provider_native?: true,
          provider_native_option_keys: [:permissions]
        ),
      workspace_context:
        capability_manifest(:common, lane, common_surface?: true, asm_option_keys: [:cwd])
    }
  end

  defp capability_map(:gemini, lane) do
    %{
      app_server: unsupported(lane),
      host_tools: unsupported(lane),
      session_resume:
        capability_manifest(:common, lane,
          common_surface?: true,
          asm_option_keys: [:continuation]
        ),
      sandbox_policy:
        capability_manifest(:sdk_local, lane,
          provider_native?: true,
          provider_native_option_keys: [:sandbox]
        ),
      approvals:
        capability_manifest(:sdk_local, lane,
          provider_native?: true,
          provider_native_option_keys: [:approval_mode]
        ),
      workspace_context:
        capability_manifest(:common, lane, common_surface?: true, asm_option_keys: [:cwd])
    }
  end

  defp capability_manifest(state, lane, opts) when state in @support_states do
    %{
      supported?: state in [:common, :native],
      lane: lane,
      provider_native?: Keyword.get(opts, :provider_native?, false),
      common_surface?: Keyword.get(opts, :common_surface?, state == :common),
      support_state: state,
      asm_option_keys: Keyword.get(opts, :asm_option_keys, []),
      provider_native_option_keys: Keyword.get(opts, :provider_native_option_keys, []),
      event_kinds: Keyword.get(opts, :event_kinds, []),
      live_example: Keyword.get(opts, :live_example),
      notes: Keyword.get(opts, :notes, [])
    }
  end

  defp unsupported(lane, opts \\ []) do
    capability_manifest(:unsupported, lane, opts)
  end
end

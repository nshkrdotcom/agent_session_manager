defmodule ASM.ProviderRegistry do
  @moduledoc """
  Resolves providers to backend lanes and runtime metadata.

  Lane selection is discovery-driven and independent from execution mode:

  - `provider_info/1` describes the provider and installed runtime-kit surface
  - `lane_info/2` resolves the preferred lane from `:auto | :core | :sdk`
  - `resolve/2` applies execution-mode compatibility to produce the effective backend
  """

  alias ASM.{AdapterSelectionPolicy, Error, Provider, ProviderRuntimeProfile}

  @type lane :: :auto | :core | :sdk
  @type execution_mode :: :local | :remote_node

  @type provider_info :: %{
          provider: Provider.t(),
          core_profile: module(),
          core_profile_id: atom(),
          sdk_runtime: module() | nil,
          sdk_available?: boolean(),
          available_lanes: [atom()],
          default_lane: :auto,
          core_capabilities: [atom()],
          sdk_capabilities: [atom()],
          observability: map()
        }

  @type lane_info :: %{
          provider: Provider.t(),
          requested_lane: lane(),
          preferred_lane: :core | :sdk,
          backend: module(),
          core_profile: module(),
          core_profile_id: atom(),
          sdk_runtime: module() | nil,
          sdk_available?: boolean(),
          available_lanes: [atom()],
          capabilities: [atom()],
          lane_reason: atom(),
          observability: map()
        }

  @type resolution :: %{
          provider: Provider.t(),
          requested_lane: lane(),
          preferred_lane: :core | :sdk,
          lane: :core | :sdk,
          backend: module(),
          sdk_available?: boolean(),
          core_profile: module(),
          core_profile_id: atom(),
          sdk_runtime: module() | nil,
          capabilities: [atom()],
          execution_mode: execution_mode(),
          lane_reason: atom(),
          lane_fallback_reason: atom() | nil,
          provider_runtime_profile: ProviderRuntimeProfile.t() | nil,
          observability: map()
        }

  @spec supported_providers() :: [atom()]
  def supported_providers do
    Provider.supported_providers()
  end

  @doc """
  Declares the Phase 6 adapter selection policy for ASM provider resolution.
  """
  @spec adapter_selection_policy() :: AdapterSelectionPolicy.t()
  def adapter_selection_policy do
    AdapterSelectionPolicy.new!(%{
      selection_surface: "provider_registry",
      owner_repo: "agent_session_manager",
      config_key: "cli_subprocess_core.provider_runtime_profiles",
      default_value_when_unset: "normal_lane_resolution",
      fail_closed_action_when_misconfigured: "force_core_lane_or_reject_required_profile"
    })
  end

  @spec fetch(atom() | Provider.t()) :: {:ok, Provider.t()} | {:error, Error.t()}
  def fetch(provider), do: Provider.resolve(provider)

  @spec core_profile_id(atom()) :: {:ok, atom()} | {:error, Error.t()}
  def core_profile_id(provider) do
    with {:ok, %Provider{} = config} <- fetch(provider) do
      {:ok, config.name}
    end
  end

  @spec provider_info(atom() | Provider.t()) :: {:ok, provider_info()} | {:error, Error.t()}
  def provider_info(provider) do
    with {:ok, %Provider{} = config} <- fetch(provider) do
      {:ok, provider_info_from_config(config)}
    end
  end

  @spec sdk_available?(atom() | Provider.t()) :: boolean()
  def sdk_available?(provider) do
    with {:ok, %Provider{} = config} <- fetch(provider),
         runtime when is_atom(runtime) <- config.sdk_runtime do
      runtime_available?(runtime)
    else
      _ -> false
    end
  end

  @spec lane_info(atom() | Provider.t(), keyword()) :: {:ok, lane_info()} | {:error, Error.t()}
  def lane_info(provider, opts \\ []) do
    with {:ok, %Provider{} = config} <- fetch(provider),
         :ok <- reject_public_simulation_selector(config.name, opts),
         {:ok, requested_lane} <- requested_lane(opts) do
      sdk_available? = sdk_available?(config)
      provider_info = provider_info_from_config(config)

      case select_preferred_lane(requested_lane, sdk_available?) do
        {:ok, preferred_lane, lane_reason} ->
          capabilities = lane_capabilities(config, preferred_lane)

          {:ok,
           %{
             provider: config,
             requested_lane: requested_lane,
             preferred_lane: preferred_lane,
             backend: backend_module(preferred_lane),
             core_profile: config.core_profile,
             core_profile_id: config.name,
             sdk_runtime: config.sdk_runtime,
             sdk_available?: sdk_available?,
             available_lanes: provider_info.available_lanes,
             capabilities: capabilities,
             lane_reason: lane_reason,
             observability:
               Map.merge(provider_info.observability, %{
                 requested_lane: requested_lane,
                 preferred_lane: preferred_lane,
                 lane_reason: lane_reason,
                 capabilities: capabilities
               })
           }}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  @spec resolve(atom(), keyword()) :: {:ok, resolution()} | {:error, Error.t()}
  def resolve(provider, opts \\ []) do
    with {:ok, info} <- lane_info(provider, opts),
         {:ok, execution_mode} <- execution_mode(opts),
         {:ok, runtime_profile} <- ProviderRuntimeProfile.resolve(info.provider.name) do
      resolve_for_execution_mode(info, execution_mode, runtime_profile)
    end
  end

  @spec resolve_lane(atom() | Provider.t(), keyword()) ::
          {:ok, :core | :sdk} | {:error, Error.t()}
  def resolve_lane(provider, opts) when is_list(opts) do
    case resolve(provider, opts) do
      {:ok, %{lane: lane}} -> {:ok, lane}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp backend_module(:core), do: ASM.ProviderBackend.Core
  defp backend_module(:sdk), do: ASM.ProviderBackend.SDK

  defp provider_info_from_config(%Provider{} = config) do
    sdk_available? = sdk_available?(config)

    %{
      provider: config,
      core_profile: config.core_profile,
      core_profile_id: config.name,
      sdk_runtime: config.sdk_runtime,
      sdk_available?: sdk_available?,
      available_lanes: available_lanes(sdk_available?),
      default_lane: :auto,
      core_capabilities: module_capabilities(config.core_profile),
      sdk_capabilities: if(sdk_available?, do: module_capabilities(config.sdk_runtime), else: []),
      observability: %{
        provider: config.name,
        provider_display_name: config.display_name,
        core_profile_id: config.name,
        sdk_runtime: config.sdk_runtime,
        sdk_available?: sdk_available?,
        available_lanes: available_lanes(sdk_available?),
        default_lane: :auto
      }
    }
  end

  defp requested_lane(opts) when is_list(opts) do
    case Keyword.get(opts, :lane, :auto) do
      lane when lane in [:auto, :core, :sdk] ->
        {:ok, lane}

      other ->
        {:error, config_error("invalid lane #{inspect(other)}; expected :auto, :core, or :sdk")}
    end
  end

  defp execution_mode(opts) when is_list(opts) do
    case Keyword.get(opts, :execution_mode, :local) do
      mode when mode in [:local, :remote_node] ->
        {:ok, mode}

      other ->
        {:error,
         config_error("invalid execution_mode #{inspect(other)}; expected :local or :remote_node")}
    end
  end

  defp select_preferred_lane(:auto, true), do: {:ok, :sdk, :sdk_available}
  defp select_preferred_lane(:auto, false), do: {:ok, :core, :sdk_unavailable}
  defp select_preferred_lane(:core, _sdk_available?), do: {:ok, :core, :explicit_core}
  defp select_preferred_lane(:sdk, true), do: {:ok, :sdk, :explicit_sdk}

  defp select_preferred_lane(:sdk, false) do
    {:error, config_error("sdk lane requested but runtime kit is unavailable")}
  end

  defp resolve_for_execution_mode(
         %{requested_lane: :sdk} = info,
         _execution_mode,
         %{ref: ref}
       ) do
    {:error,
     config_error(
       "sdk lane is unavailable while provider runtime profile #{inspect(ref)} is active for #{inspect(info.provider.name)}"
     )}
  end

  defp resolve_for_execution_mode(%{} = info, execution_mode, %{} = runtime_profile) do
    lane_fallback_reason =
      if info.preferred_lane == :core do
        nil
      else
        :provider_runtime_profile
      end

    finalize_resolution(info, :core, execution_mode, lane_fallback_reason, runtime_profile)
  end

  defp resolve_for_execution_mode(
         %{requested_lane: :sdk, preferred_lane: :sdk},
         :remote_node,
         nil
       ) do
    {:error, config_error("sdk lane is unavailable for :remote_node execution")}
  end

  defp resolve_for_execution_mode(%{preferred_lane: :sdk} = info, :remote_node, nil) do
    finalize_resolution(info, :core, :remote_node, :sdk_remote_unsupported, nil)
  end

  defp resolve_for_execution_mode(%{} = info, execution_mode, nil) do
    finalize_resolution(info, info.preferred_lane, execution_mode, nil, nil)
  end

  defp finalize_resolution(
         %{} = info,
         lane,
         execution_mode,
         lane_fallback_reason,
         runtime_profile
       ) do
    capabilities = lane_capabilities(info.provider, lane)

    {:ok,
     %{
       provider: info.provider,
       requested_lane: info.requested_lane,
       preferred_lane: info.preferred_lane,
       lane: lane,
       backend: backend_module(lane),
       sdk_available?: info.sdk_available?,
       core_profile: info.core_profile,
       core_profile_id: info.core_profile_id,
       sdk_runtime: info.sdk_runtime,
       capabilities: capabilities,
       execution_mode: execution_mode,
       lane_reason: info.lane_reason,
       lane_fallback_reason: lane_fallback_reason,
       provider_runtime_profile: runtime_profile,
       observability:
         Map.merge(info.observability, %{
           lane: lane,
           backend: backend_module(lane),
           execution_mode: execution_mode,
           capabilities: capabilities,
           lane_fallback_reason: lane_fallback_reason
         })
         |> Map.merge(ProviderRuntimeProfile.observability(runtime_profile))
     }}
  end

  defp available_lanes(true), do: [:core, :sdk]
  defp available_lanes(false), do: [:core]

  defp lane_capabilities(%Provider{} = config, :core),
    do: module_capabilities(config.core_profile)

  defp lane_capabilities(%Provider{} = config, :sdk), do: module_capabilities(config.sdk_runtime)

  defp module_capabilities(module) when is_atom(module) do
    if runtime_available?(module) and function_exported?(module, :capabilities, 0) do
      module.capabilities()
    else
      []
    end
  end

  defp runtime_available?(runtime) when is_atom(runtime) do
    case runtime_loader().(runtime) do
      true -> true
      {:module, _module} -> true
      _ -> false
    end
  end

  defp runtime_loader do
    :agent_session_manager
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:runtime_loader, &Code.ensure_loaded?/1)
  end

  defp reject_public_simulation_selector(provider, opts) when is_list(opts) do
    if Enum.any?(opts, &public_simulation_entry?/1) do
      {:error,
       config_error(
         "public simulation selector is forbidden; use owner registry configuration",
         provider,
         %{provider: provider, forbidden_key: :simulation}
       )}
    else
      :ok
    end
  end

  defp public_simulation_entry?({key, _value}), do: key in [:simulation, "simulation"]
  defp public_simulation_entry?(_entry), do: false

  defp config_error(message, provider \\ nil, cause \\ nil) do
    Error.new(:config_invalid, :config, message, provider: provider, cause: cause)
  end
end

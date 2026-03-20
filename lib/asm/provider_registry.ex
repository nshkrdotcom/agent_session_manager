defmodule ASM.ProviderRegistry do
  @moduledoc """
  Resolves providers to backend lanes and runtime metadata.
  """

  alias ASM.{Error, Provider}

  @type lane :: :auto | :core | :sdk

  @type resolution :: %{
          provider: Provider.t(),
          lane: :core | :sdk,
          backend: module(),
          sdk_available?: boolean(),
          core_profile: module(),
          observability: map()
        }

  @spec supported_providers() :: [atom()]
  def supported_providers do
    Provider.supported_providers()
  end

  @spec fetch(atom()) :: {:ok, Provider.t()} | {:error, Error.t()}
  def fetch(provider), do: Provider.resolve(provider)

  @spec core_profile_id(atom()) :: {:ok, atom()} | {:error, Error.t()}
  def core_profile_id(provider) do
    with {:ok, %Provider{} = config} <- fetch(provider) do
      {:ok, config.name}
    end
  end

  @spec sdk_available?(atom()) :: boolean()
  def sdk_available?(provider) do
    with {:ok, %Provider{} = config} <- fetch(provider),
         runtime when is_atom(runtime) <- config.sdk_runtime do
      Code.ensure_loaded?(runtime)
    else
      _ -> false
    end
  end

  @spec resolve(atom(), keyword()) :: {:ok, resolution()} | {:error, Error.t()}
  def resolve(provider, opts \\ []) do
    with {:ok, %Provider{} = config} <- fetch(provider),
         {:ok, lane} <- resolve_lane(config, opts) do
      {:ok,
       %{
         provider: config,
         lane: lane,
         backend: backend_module(lane),
         sdk_available?: sdk_available?(provider),
         core_profile: config.core_profile,
         observability: %{
           provider: config.name,
           lane: lane,
           sdk_runtime: config.sdk_runtime
         }
       }}
    end
  end

  @spec resolve_lane(Provider.t(), keyword()) :: {:ok, :core | :sdk} | {:error, Error.t()}
  def resolve_lane(%Provider{} = provider, opts) when is_list(opts) do
    requested_lane = Keyword.get(opts, :lane, :auto)
    execution_mode = Keyword.get(opts, :execution_mode, :local)
    sdk_available? = sdk_available?(provider.name)

    case {requested_lane, execution_mode, sdk_available?} do
      {:auto, :remote_node, _} ->
        {:ok, :core}

      {:auto, _mode, true} ->
        {:ok, :sdk}

      {:auto, _mode, false} ->
        {:ok, :core}

      {:core, _mode, _} ->
        {:ok, :core}

      {:sdk, :remote_node, _} ->
        {:error, config_error("sdk lane is unavailable for :remote_node execution")}

      {:sdk, _mode, true} ->
        {:ok, :sdk}

      {:sdk, _mode, false} ->
        {:error, config_error("sdk lane requested but runtime kit is unavailable")}

      {other, _mode, _} ->
        {:error, config_error("invalid lane #{inspect(other)}; expected :auto, :core, or :sdk")}
    end
  end

  defp backend_module(:core), do: ASM.ProviderBackend.Core
  defp backend_module(:sdk), do: ASM.ProviderBackend.SDK

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end

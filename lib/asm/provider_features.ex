defmodule ASM.ProviderFeatures do
  @moduledoc """
  Public provider feature manifests for ASM.

  This module exposes two related surfaces:

  - provider-native permission mode metadata inherited from
    `CliSubprocessCore.ProviderFeatures`
  - ASM common features that are only supported by some providers, such as the
    common Ollama surface
  """

  alias ASM.{Error, Provider}
  alias CliSubprocessCore.ProviderFeatures, as: CoreProviderFeatures

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
          common_features: %{optional(atom()) => common_feature_manifest()}
        }

  @spec manifest(Provider.t() | Provider.provider_name()) ::
          {:ok, manifest()} | {:error, Error.t()}
  def manifest(provider_or_name) do
    with {:ok, %Provider{} = provider} <- Provider.resolve(provider_or_name) do
      {:ok,
       %{
         provider: provider.name,
         permission_modes: core_permission_modes(provider.name),
         common_features: provider.feature_manifest
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

  defp core_permission_modes(provider) when is_atom(provider) do
    provider
    |> CoreProviderFeatures.manifest!()
    |> Map.fetch!(:permission_modes)
  end
end

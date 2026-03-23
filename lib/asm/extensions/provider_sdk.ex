defmodule ASM.Extensions.ProviderSDK do
  @moduledoc """
  Public discovery API for optional provider-native extension namespaces.

  This boundary sits above ASM's normalized kernel. It reports which richer
  provider-native surfaces may be present without widening the kernel API or
  making provider SDK packages mandatory for core execution.

  Use `ASM.ProviderRegistry` for normalized lane/runtime discovery and
  `ASM.Extensions.ProviderSDK` for provider-native extension discovery.

  Discovery is intentionally split into registered-versus-active views:

  - `extensions/0` and `provider_extensions/1` return the static Claude/Codex
    native-extension catalog that ASM knows about
  - `available_extensions/0` and `available_provider_extensions/1` return only
    the active subset for the currently installed optional deps
  - `provider_report/1` and `capability_report/0` expose both views through
    `registered_namespaces` versus `namespaces`

  Gemini and Amp may therefore compose with `sdk_available?: true` while still
  reporting no native namespaces, because they currently use only the common
  ASM surface plus the optional SDK lane/runtime kit.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      ASM.Extensions.ProviderSDK,
      ASM.Extensions.ProviderSDK.Extension,
      ASM.Extensions.ProviderSDK.Claude,
      ASM.Extensions.ProviderSDK.Codex
    ]

  alias ASM.{Error, Provider, ProviderRegistry}
  alias ASM.Extensions.ProviderSDK.Extension

  @catalog [
    ASM.Extensions.ProviderSDK.Claude,
    ASM.Extensions.ProviderSDK.Codex
  ]

  @typedoc """
  Active and registered provider-native composition facts for one provider.

  `registered_namespaces` and `registered_extensions` describe the static
  catalog ASM ships for that provider. `namespaces` and `extensions` describe
  the active subset for the currently installed optional deps.
  """
  @type provider_report :: %{
          provider: Provider.provider_name(),
          composition_mode: :common_surface_only | :native_extension,
          registered_namespaces: [module()],
          namespaces: [module()],
          sdk_available?: boolean(),
          registered_extensions: [Extension.t()],
          native_capabilities: [atom()],
          native_surface_modules: [module()],
          extensions: [Extension.t()]
        }

  @doc """
  Returns ASM's static provider-native extension catalog.

  This is the compile-time Claude/Codex catalog that ASM ships, regardless of
  whether the matching optional provider SDK deps are active in the current
  application.
  """
  @spec extensions() :: [Extension.t()]
  def extensions do
    @catalog
    |> Enum.map(& &1.extension())
    |> Enum.sort_by(& &1.provider)
  end

  @doc """
  Returns the active provider-native extension catalog for the current deps.
  """
  @spec available_extensions() :: [Extension.t()]
  def available_extensions do
    Enum.filter(extensions(), & &1.sdk_available?)
  end

  @doc """
  Returns the active provider-native extensions for one provider.

  Providers with no active native namespace return `{:ok, []}`.
  """
  @spec available_provider_extensions(Provider.provider_name() | Provider.t()) ::
          {:ok, [Extension.t()]} | {:error, Error.t()}
  def available_provider_extensions(provider) do
    with {:ok, report} <- provider_report(provider) do
      {:ok, report.extensions}
    end
  end

  @doc """
  Resolves one registered provider-native extension by provider atom or module.
  """
  @spec extension(atom() | module()) :: {:ok, Extension.t()} | {:error, Error.t()}
  def extension(identifier) when is_atom(identifier) do
    with {:ok, module} <- extension_module(identifier) do
      {:ok, module.extension()}
    end
  end

  @doc """
  Returns whether a registered provider-native extension is active locally.
  """
  @spec available?(atom() | module()) :: boolean()
  def available?(identifier) when is_atom(identifier) do
    case extension(identifier) do
      {:ok, %Extension{} = extension} -> extension.sdk_available?
      {:error, %Error{}} -> false
    end
  end

  @doc """
  Returns the registered provider-native extension catalog for one provider.

  This reports what ASM knows how to expose for that provider, even if the
  matching optional dependency is currently inactive.
  """
  @spec provider_extensions(Provider.provider_name() | Provider.t()) ::
          {:ok, [Extension.t()]} | {:error, Error.t()}
  def provider_extensions(provider) do
    with {:ok, %Provider{name: provider_name}} <- Provider.resolve(provider) do
      {:ok, Enum.filter(extensions(), &(&1.provider == provider_name))}
    end
  end

  @doc """
  Returns the active provider-native capability labels for one provider.
  """
  @spec provider_capabilities(Provider.provider_name() | Provider.t()) ::
          {:ok, [atom()]} | {:error, Error.t()}
  def provider_capabilities(provider) do
    with {:ok, extensions} <- available_provider_extensions(provider) do
      {:ok,
       extensions
       |> Enum.flat_map(& &1.native_capabilities)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  @doc """
  Returns active and registered composition facts for one provider.

  `sdk_available?` reports whether the provider runtime kit is loadable for the
  current dependency set. `registered_namespaces` reports the static ASM
  catalog, while `namespaces` reports the active subset.
  """
  @spec provider_report(Provider.provider_name() | Provider.t()) ::
          {:ok, provider_report()} | {:error, Error.t()}
  def provider_report(provider) do
    with {:ok, %Provider{name: provider_name}} <- Provider.resolve(provider),
         {:ok, provider_info} <- ProviderRegistry.provider_info(provider_name) do
      registered_extensions = registered_provider_extensions(provider_name)
      extensions = Enum.filter(registered_extensions, & &1.sdk_available?)

      {:ok,
       %{
         provider: provider_name,
         composition_mode: composition_mode(extensions),
         registered_namespaces: Enum.map(registered_extensions, & &1.namespace),
         namespaces: Enum.map(extensions, & &1.namespace),
         sdk_available?: provider_info.sdk_available?,
         registered_extensions: registered_extensions,
         native_capabilities:
           extensions
           |> Enum.flat_map(& &1.native_capabilities)
           |> Enum.uniq()
           |> Enum.sort(),
         native_surface_modules:
           extensions
           |> Enum.flat_map(& &1.native_surface_modules)
           |> Enum.uniq()
           |> Enum.sort(),
         extensions: extensions
       }}
    end
  end

  @doc """
  Returns `provider_report/1` for every ASM provider.
  """
  @spec capability_report() :: %{optional(Provider.provider_name()) => provider_report()}
  def capability_report do
    Provider.supported_providers()
    |> Enum.map(fn provider ->
      {:ok, report} = provider_report(provider)
      {provider, report}
    end)
    |> Enum.into(%{})
  end

  defp extension_module(module) when module in @catalog, do: {:ok, module}

  defp extension_module(identifier) when is_atom(identifier) do
    with {:ok, %Provider{name: provider_name}} <- Provider.resolve(identifier) do
      case Enum.find(@catalog, &(provider_name == extension_provider(&1))) do
        nil ->
          {:error,
           Error.new(
             :config_invalid,
             :config,
             "no provider SDK extension is registered for #{inspect(provider_name)}"
           )}

        module ->
          {:ok, module}
      end
    end
  end

  defp registered_provider_extensions(provider_name) do
    Enum.filter(extensions(), &(&1.provider == provider_name))
  end

  defp extension_provider(module) when is_atom(module) do
    module.extension().provider
  end

  defp composition_mode([]), do: :common_surface_only
  defp composition_mode(_extensions), do: :native_extension
end

defmodule ASM.Extensions.ProviderSDK do
  @moduledoc """
  Public discovery API for optional provider-native extension namespaces.

  This boundary sits above ASM's normalized kernel. It reports which richer
  provider-native surfaces may be present without widening the kernel API or
  making provider SDK packages mandatory for core execution.

  Use `ASM.ProviderRegistry` for normalized lane/runtime discovery and
  `ASM.Extensions.ProviderSDK` for provider-native extension discovery.
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

  @spec extensions() :: [Extension.t()]
  def extensions do
    @catalog
    |> Enum.map(& &1.extension())
    |> Enum.sort_by(& &1.provider)
  end

  @spec available_extensions() :: [Extension.t()]
  def available_extensions do
    Enum.filter(extensions(), & &1.sdk_available?)
  end

  @spec available_provider_extensions(Provider.provider_name() | Provider.t()) ::
          {:ok, [Extension.t()]} | {:error, Error.t()}
  def available_provider_extensions(provider) do
    with {:ok, report} <- provider_report(provider) do
      {:ok, report.extensions}
    end
  end

  @spec extension(atom() | module()) :: {:ok, Extension.t()} | {:error, Error.t()}
  def extension(identifier) when is_atom(identifier) do
    with {:ok, module} <- extension_module(identifier) do
      {:ok, module.extension()}
    end
  end

  @spec available?(atom() | module()) :: boolean()
  def available?(identifier) when is_atom(identifier) do
    case extension(identifier) do
      {:ok, %Extension{} = extension} -> extension.sdk_available?
      {:error, %Error{}} -> false
    end
  end

  @spec provider_extensions(Provider.provider_name() | Provider.t()) ::
          {:ok, [Extension.t()]} | {:error, Error.t()}
  def provider_extensions(provider) do
    with {:ok, %Provider{name: provider_name}} <- Provider.resolve(provider) do
      {:ok, Enum.filter(extensions(), &(&1.provider == provider_name))}
    end
  end

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

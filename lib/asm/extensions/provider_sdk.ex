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

  alias ASM.{Error, Provider}
  alias ASM.Extensions.ProviderSDK.Extension

  @catalog [
    ASM.Extensions.ProviderSDK.Claude,
    ASM.Extensions.ProviderSDK.Codex
  ]

  @type provider_report :: %{
          provider: Provider.provider_name(),
          namespaces: [module()],
          sdk_available?: boolean(),
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
    with {:ok, extensions} <- provider_extensions(provider) do
      {:ok,
       extensions
       |> Enum.flat_map(& &1.native_capabilities)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  @spec capability_report() :: %{optional(Provider.provider_name()) => provider_report()}
  def capability_report do
    extensions()
    |> Enum.group_by(& &1.provider)
    |> Enum.into(%{}, fn {provider, extensions} ->
      {provider,
       %{
         provider: provider,
         namespaces: Enum.map(extensions, & &1.namespace),
         sdk_available?: Enum.any?(extensions, & &1.sdk_available?),
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
    end)
  end

  defp extension_module(module) when module in @catalog, do: {:ok, module}

  defp extension_module(identifier) when is_atom(identifier) do
    with {:ok, %Provider{name: provider_name}} <- Provider.resolve(identifier) do
      case Enum.find(@catalog, &(provider_name == &1.extension().provider)) do
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
end

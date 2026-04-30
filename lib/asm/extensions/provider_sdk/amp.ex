defmodule ASM.Extensions.ProviderSDK.Amp do
  @moduledoc """
  Discovery metadata and strict derivation helpers for the optional Amp-native
  ASM extension namespace.

  This namespace derives only common ASM placement/session data into
  `AmpSdk.Types.Options`. Amp-native controls such as permissions, MCP,
  skills, thread controls, labels, IDE behavior, and notification behavior must
  be passed explicitly through `:native_overrides` or through direct `amp_sdk`
  APIs.
  """

  alias ASM.Extensions.ProviderSDK.{Derivation, Extension}
  alias ASM.ProviderRegistry

  @sdk_app :amp_sdk
  @sdk_module Module.concat(["AmpSdk"])
  @sdk_options_module Module.concat(["AmpSdk", "Types", "Options"])
  @runtime_module Module.concat(["AmpSdk", "Runtime", "CLI"])
  @management_types_module Module.concat(["AmpSdk", "ManagementTypes"])
  @native_capabilities [:mcp, :permissions, :skills, :threads]
  @native_surface_modules [@runtime_module, @management_types_module]
  @asm_derived_option_keys [
    :cwd,
    :execution_surface,
    :stream_timeout_ms,
    :model_payload
  ]

  @spec extension() :: Extension.t()
  def extension do
    Extension.new!(
      id: :amp,
      provider: :amp,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Amp-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: ProviderRegistry.sdk_available?(:amp)

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules

  @doc """
  Derives `AmpSdk.Types.Options` from strict common ASM options.

  Provider-native Amp options must be supplied in `:native_overrides`; they are
  never read from the generic ASM option map.
  """
  @spec derive_options(keyword(), keyword()) :: {:ok, struct()} | {:error, term()}
  def derive_options(asm_common, opts \\ [])
      when is_list(asm_common) and is_list(opts) do
    native_overrides = Keyword.get(opts, :native_overrides, [])

    with {:ok, preflight} <- Derivation.strict_common(:amp, asm_common),
         :ok <-
           Derivation.ensure_native_override_boundary(
             native_overrides,
             @asm_derived_option_keys,
             "Amp"
           ) do
      attrs =
        preflight.common
        |> sdk_option_attrs()
        |> Keyword.merge(native_overrides)

      Derivation.build_sdk_options(@sdk_options_module, attrs, "Amp")
    end
  end

  defp sdk_option_attrs(common) when is_map(common) do
    []
    |> Derivation.maybe_put(:cwd, Map.get(common, :cwd))
    |> Derivation.maybe_put(:execution_surface, Map.get(common, :execution_surface))
    |> Derivation.maybe_put(:stream_timeout_ms, Map.get(common, :transport_timeout_ms))
  end
end

defmodule ASM.Extensions.ProviderSDK.Gemini do
  @moduledoc """
  Discovery metadata and strict derivation helpers for the optional
  Gemini-native ASM extension namespace.

  This namespace derives only common ASM placement/session data into
  `GeminiCliSdk.Options`. Gemini-native controls such as settings profiles,
  CLI extensions, allowed tools, MCP server names, trust controls, sandbox
  flags, and provider-native system prompts must be passed explicitly through
  `:native_overrides` or through direct `gemini_cli_sdk` APIs.
  """

  alias ASM.Extensions.ProviderSDK.{Derivation, Extension}
  alias ASM.ProviderRegistry

  @sdk_app :gemini_cli_sdk
  @sdk_module Module.concat(["GeminiCliSdk"])
  @sdk_options_module Module.concat(["GeminiCliSdk", "Options"])
  @settings_profiles_module Module.concat(["GeminiCliSdk", "SettingsProfiles"])
  @runtime_module Module.concat(["GeminiCliSdk", "Runtime", "CLI"])
  @native_capabilities [:extensions, :settings_profiles, :trust_controls]
  @native_surface_modules [@settings_profiles_module, @runtime_module]
  @asm_derived_option_keys [
    :model,
    :model_payload,
    :cli_command,
    :cwd,
    :execution_surface,
    :timeout_ms
  ]

  @spec extension() :: Extension.t()
  def extension do
    Extension.new!(
      id: :gemini,
      provider: :gemini,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Gemini-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: ProviderRegistry.sdk_available?(:gemini)

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules

  @doc """
  Derives `GeminiCliSdk.Options` from strict common ASM options.

  Provider-native Gemini options must be supplied in `:native_overrides`; they
  are never read from the generic ASM option map.
  """
  @spec derive_options(keyword(), keyword()) :: {:ok, struct()} | {:error, term()}
  def derive_options(asm_common, opts \\ [])
      when is_list(asm_common) and is_list(opts) do
    native_overrides = Keyword.get(opts, :native_overrides, [])

    with {:ok, preflight} <- Derivation.strict_common(:gemini, asm_common),
         :ok <-
           Derivation.ensure_native_override_boundary(
             native_overrides,
             @asm_derived_option_keys,
             "Gemini"
           ) do
      attrs =
        preflight.common
        |> sdk_option_attrs()
        |> Keyword.merge(native_overrides)

      Derivation.build_sdk_options(@sdk_options_module, attrs, "Gemini")
    end
  end

  defp sdk_option_attrs(common) when is_map(common) do
    []
    |> Derivation.maybe_put(:model, Map.get(common, :model))
    |> Derivation.maybe_put(:cli_command, Map.get(common, :cli_path))
    |> Derivation.maybe_put(:cwd, Map.get(common, :cwd))
    |> Derivation.maybe_put(:execution_surface, Map.get(common, :execution_surface))
    |> Derivation.maybe_put(:timeout_ms, Map.get(common, :transport_timeout_ms))
  end
end

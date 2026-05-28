defmodule ASM.Extensions.ProviderSDK.Cursor do
  @moduledoc """
  Discovery metadata and strict derivation helpers for the optional
  Cursor-native ASM extension namespace.

  Cursor's SDK lane is enabled once `cursor_cli_sdk` is present. Core-lane
  Cursor execution remains owned by `CliSubprocessCore.ProviderProfiles.Cursor`.
  """

  alias ASM.Extensions.ProviderSDK.{Derivation, Extension}
  alias ASM.ProviderRegistry

  @sdk_app :cursor_cli_sdk
  @sdk_module :"Elixir.CursorCliSdk"
  @sdk_options_module :"Elixir.CursorCliSdk.Options"
  @runtime_module :"Elixir.CursorCliSdk.Runtime.CLI"
  @native_capabilities [:mcp, :plugins, :worktrees]
  @native_surface_modules [@runtime_module]
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
      id: :cursor,
      provider: :cursor,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Cursor-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: ProviderRegistry.sdk_available?(:cursor)

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules

  @doc """
  Derives `CursorCliSdk.Options` from strict common ASM options.

  Cursor-native controls such as `:mode`, `:sandbox`, `:approve_mcps`,
  worktree flags, plugin directories, and headers belong in `:native_overrides`.
  """
  @spec derive_options(keyword(), keyword()) :: {:ok, struct()} | {:error, term()}
  def derive_options(asm_common, opts \\ [])
      when is_list(asm_common) and is_list(opts) do
    native_overrides = Keyword.get(opts, :native_overrides, [])

    with {:ok, preflight} <- Derivation.strict_common(:cursor, asm_common),
         :ok <-
           Derivation.ensure_native_override_boundary(
             native_overrides,
             @asm_derived_option_keys,
             "Cursor"
           ) do
      attrs =
        preflight.common
        |> sdk_option_attrs()
        |> Keyword.merge(native_overrides)

      Derivation.build_sdk_options(@sdk_options_module, attrs, "Cursor")
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

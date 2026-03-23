defmodule ASM.Extensions.ProviderSDK.Claude do
  @moduledoc """
  Discovery metadata for the optional Claude-native ASM extension namespace.

  This module does not implement Claude's richer APIs. It only declares the
  namespace and native surface inventory that lives above ASM's normalized
  kernel.
  """

  alias ASM.Extensions.ProviderSDK.Extension

  @sdk_app :claude_agent_sdk
  @sdk_module Module.concat(["ClaudeAgentSDK"])
  @native_capabilities [:control_protocol, :hooks, :permission_callbacks]

  @native_surface_modules [
    Module.concat(["ClaudeAgentSDK", "ControlProtocol", "Protocol"]),
    Module.concat(["ClaudeAgentSDK", "Hooks"]),
    Module.concat(["ClaudeAgentSDK", "Permission"])
  ]

  @spec extension() :: Extension.t()
  def extension do
    Extension.new!(
      id: :claude,
      provider: :claude,
      namespace: __MODULE__,
      sdk_app: @sdk_app,
      sdk_module: @sdk_module,
      description: "Optional Claude-native extension namespace above the normalized ASM kernel.",
      sdk_available?: available?(),
      native_capabilities: @native_capabilities,
      native_surface_modules: @native_surface_modules
    )
  end

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@sdk_module)

  @spec sdk_app() :: atom()
  def sdk_app, do: @sdk_app

  @spec sdk_module() :: module()
  def sdk_module, do: @sdk_module

  @spec native_capabilities() :: [atom()]
  def native_capabilities, do: @native_capabilities

  @spec native_surface_modules() :: [module()]
  def native_surface_modules, do: @native_surface_modules
end

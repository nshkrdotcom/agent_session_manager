defmodule ASM.Provider.Gemini do
  @moduledoc """
  Gemini provider definition for exec stdio mode.
  """

  alias ASM.Provider
  alias ASM.Provider.Profile

  @behaviour Provider

  @impl true
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      name: :gemini,
      display_name: "Gemini CLI",
      binary_names: ["gemini"],
      env_var: "GEMINI_CLI_PATH",
      install_command: "npm install -g @google/gemini-cli",
      parser: ASM.Parser.Gemini,
      command_builder: ASM.Command.Gemini,
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :flag,
          control_mode: :none,
          session_mode: :provider_managed,
          transport_restart: :temporary,
          max_concurrent_runs: 4,
          max_queued_runs: 0
        ),
      options_schema: ASM.Options.Gemini.schema(),
      supports_streaming: true,
      supports_control: false,
      supports_resume: true,
      supports_thinking: true,
      supports_tools: true,
      npm_package: "@google/gemini-cli",
      npx_package: "@google/gemini-cli",
      disable_npx_env: "GEMINI_NO_NPX"
    }
  end
end

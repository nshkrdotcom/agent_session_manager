defmodule ASM.Provider.CodexExec do
  @moduledoc """
  Codex provider definition for exec stdio mode.
  """

  alias ASM.Provider
  alias ASM.Provider.Profile

  @behaviour Provider

  @impl true
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      name: :codex_exec,
      display_name: "Codex CLI (exec)",
      binary_names: ["codex"],
      env_var: "CODEX_PATH",
      install_command: "npm install -g @openai/codex",
      parser: ASM.Parser.Codex,
      command_builder: ASM.Command.Codex,
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :stdin,
          control_mode: :none,
          session_mode: :asm_managed,
          transport_restart: :temporary,
          max_concurrent_runs: 4,
          max_queued_runs: 0
        ),
      options_schema: ASM.Options.Codex.schema(),
      supports_streaming: true,
      supports_control: false,
      supports_resume: false,
      supports_thinking: true,
      supports_tools: true
    }
  end
end

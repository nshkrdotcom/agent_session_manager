defmodule ASM.Provider.Claude do
  @moduledoc """
  Claude provider definition for persistent stdio mode.
  """

  alias ASM.Provider
  alias ASM.Provider.Profile

  @behaviour Provider

  @impl true
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      name: :claude,
      display_name: "Claude CLI",
      binary_names: ["claude", "claude-code"],
      env_var: "CLAUDE_CLI_PATH",
      install_command: "npm install -g @anthropic-ai/claude-code",
      parser: ASM.Parser.Claude,
      command_builder: ASM.Command.Claude,
      profile:
        Profile.new!(
          transport_mode: :persistent_stdio,
          input_mode: :stdin,
          control_mode: :stdio_bidirectional,
          session_mode: :provider_managed,
          transport_restart: :transient,
          max_concurrent_runs: 1,
          max_queued_runs: 10
        ),
      options_schema: ASM.Options.Claude.schema(),
      supports_streaming: true,
      supports_control: true,
      supports_resume: true,
      supports_thinking: true,
      supports_tools: true
    }
  end
end

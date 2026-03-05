defmodule ASM.Provider.Shell do
  @moduledoc """
  Shell provider definition for controlled command execution workflows.
  """

  alias ASM.Provider
  alias ASM.Provider.Profile

  @behaviour Provider

  @impl true
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      name: :shell,
      display_name: "Shell",
      binary_names: ["sh", "bash"],
      env_var: "ASM_SHELL_PATH",
      install_command: nil,
      parser: ASM.Parser.Shell,
      command_builder: ASM.Command.Shell,
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :flag,
          control_mode: :none,
          session_mode: :asm_managed,
          transport_restart: :temporary,
          max_concurrent_runs: 2,
          max_queued_runs: 10
        ),
      options_schema: ASM.Options.Shell.schema(),
      supports_streaming: true,
      supports_control: false,
      supports_resume: false,
      supports_thinking: false,
      supports_tools: false,
      metadata: %{extension: true}
    }
  end
end

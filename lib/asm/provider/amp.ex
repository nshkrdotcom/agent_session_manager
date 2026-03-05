defmodule ASM.Provider.Amp do
  @moduledoc """
  Amp provider definition for exec stdio mode.

  Decision: CLI-first integration via the existing transport seam.
  If SDK-only streaming gaps emerge, follow ADR-0011 and add a driver-seam path.
  """

  alias ASM.Provider
  alias ASM.Provider.Profile

  @behaviour Provider

  @impl true
  @spec provider() :: Provider.t()
  def provider do
    %Provider{
      name: :amp,
      display_name: "Amp CLI",
      binary_names: ["amp"],
      env_var: "AMP_CLI_PATH",
      install_command: nil,
      parser: ASM.Parser.Amp,
      command_builder: ASM.Command.Amp,
      profile:
        Profile.new!(
          transport_mode: :exec_stdio,
          input_mode: :stdin,
          control_mode: :none,
          session_mode: :provider_managed,
          transport_restart: :temporary,
          max_concurrent_runs: 2,
          max_queued_runs: 10
        ),
      options_schema: ASM.Options.Amp.schema(),
      supports_streaming: true,
      supports_control: false,
      supports_resume: false,
      supports_thinking: true,
      supports_tools: true
    }
  end
end

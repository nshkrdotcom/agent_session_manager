defmodule ASM.Options.Shell do
  @moduledoc """
  Shell provider-specific option schema.
  """

  @default_allowed_commands [
    "echo",
    "pwd",
    "ls",
    "cat",
    "head",
    "tail",
    "wc",
    "date",
    "whoami",
    "uname",
    "true",
    "false",
    "sleep"
  ]

  @default_denied_commands [
    "rm",
    "sudo",
    "su",
    "chmod",
    "chown",
    "dd",
    "mkfs",
    "shutdown",
    "reboot",
    "kill",
    "killall"
  ]

  @spec schema() :: keyword()
  def schema do
    [
      allowed_commands: [type: {:list, :string}, default: @default_allowed_commands],
      denied_commands: [type: {:list, :string}, default: @default_denied_commands],
      command_timeout_ms: [type: :pos_integer, default: 30_000],
      success_exit_codes: [type: {:list, :non_neg_integer}, default: [0]]
    ]
  end
end

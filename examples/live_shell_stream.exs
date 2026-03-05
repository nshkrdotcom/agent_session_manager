Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

parse_csv = fn
  nil ->
    nil

  "" ->
    nil

  value ->
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
end

parse_int = fn
  nil, default ->
    default

  "", default ->
    default

  value, default ->
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
end

command = LiveSupport.prompt_from_argv_or_default("echo SHELL_OK")

allowed_commands =
  parse_csv.(System.get_env("ASM_SHELL_ALLOWED")) ||
    ["echo", "pwd", "ls", "cat", "head", "tail", "wc", "date", "whoami", "uname", "sleep"]

denied_commands =
  parse_csv.(System.get_env("ASM_SHELL_DENIED")) ||
    ["rm", "sudo", "su", "chmod", "chown", "dd", "mkfs", "shutdown", "reboot", "kill", "killall"]

opts = [
  permission_mode: System.get_env("ASM_PERMISSION_MODE") || "default",
  cli_path: System.get_env("ASM_SHELL_PATH"),
  allowed_commands: allowed_commands,
  denied_commands: denied_commands,
  command_timeout_ms: parse_int.(System.get_env("ASM_SHELL_TIMEOUT_MS"), 5_000),
  success_exit_codes: [0]
]

IO.puts("""
WARNING: The shell provider executes local commands.
Run this example only inside a disposable sandbox/workspace with least-privilege credentials.
Default policy is allow-listed and denies high-risk commands; customize with ASM_SHELL_ALLOWED/ASM_SHELL_DENIED.
""")

LiveSupport.ensure_cli!(:shell, Keyword.take(opts, [:cli_path]))
_ = LiveSupport.stream_and_collect!(:shell, command, opts)

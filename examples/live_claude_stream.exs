Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

prompt =
  LiveSupport.prompt_from_argv_or_default("Reply with exactly: CLAUDE_OK")

opts =
  []
  |> put_opt.(:model, System.get_env("ASM_CLAUDE_MODEL"))
  |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
  |> put_opt.(:cli_path, System.get_env("CLAUDE_CLI_PATH"))

LiveSupport.ensure_cli!(:claude, Keyword.take(opts, [:cli_path]))
_ = LiveSupport.stream_and_collect!(:claude, prompt, opts)

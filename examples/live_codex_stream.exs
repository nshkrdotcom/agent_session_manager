Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

prompt =
  LiveSupport.prompt_from_argv_or_default("Reply with exactly: CODEX_OK")

reasoning_effort =
  case System.get_env("ASM_CODEX_REASONING") do
    nil -> nil
    "" -> nil
    "low" -> :low
    "medium" -> :medium
    "high" -> :high
    _ -> nil
  end

opts =
  []
  |> put_opt.(:model, System.get_env("ASM_CODEX_MODEL"))
  |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
  |> put_opt.(:cli_path, System.get_env("CODEX_PATH"))
  |> put_opt.(:reasoning_effort, reasoning_effort)

LiveSupport.ensure_cli!(:codex, Keyword.take(opts, [:cli_path]))
_ = LiveSupport.stream_and_collect!(:codex, prompt, opts)

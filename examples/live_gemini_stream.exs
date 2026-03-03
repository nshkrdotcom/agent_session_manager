Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

prompt =
  LiveSupport.prompt_from_argv_or_default("Reply with exactly: GEMINI_OK")

extensions =
  case System.get_env("ASM_GEMINI_EXTENSIONS") do
    nil -> []
    "" -> []
    value -> String.split(value, ",", trim: true)
  end

opts =
  []
  |> put_opt.(:model, System.get_env("ASM_GEMINI_MODEL"))
  |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
  |> put_opt.(:cli_path, System.get_env("GEMINI_CLI_PATH"))
  |> Keyword.put(:extensions, extensions)

LiveSupport.ensure_cli!(:gemini, Keyword.take(opts, [:cli_path]))
_ = LiveSupport.stream_and_collect!(:gemini, prompt, opts)

Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

providers = [
  {:claude, "CLAUDE_CLI_PATH", "ASM_CLAUDE_MODEL"},
  {:gemini, "GEMINI_CLI_PATH", "ASM_GEMINI_MODEL"},
  {:codex, "CODEX_PATH", "ASM_CODEX_MODEL"}
]

Enum.each(providers, fn {provider, cli_env, model_env} ->
  opts =
    []
    |> put_opt.(:cli_path, System.get_env(cli_env))
    |> put_opt.(:model, System.get_env(model_env))
    |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")

  IO.puts("\n== Provider feature matrix: #{provider} ==")
  LiveSupport.ensure_cli!(provider, Keyword.take(opts, [:cli_path]))

  _ =
    LiveSupport.run_session_feature_matrix!(
      provider,
      "Reply with exactly: #{provider |> Atom.to_string() |> String.upcase()}_STREAM_OK",
      "Reply with exactly: #{provider |> Atom.to_string() |> String.upcase()}_QUERY_OK",
      opts
    )
end)

IO.puts("\nall provider feature matrix checks completed")

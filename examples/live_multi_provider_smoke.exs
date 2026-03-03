Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

providers = [
  {:claude, "CLAUDE_CLI_PATH", "Reply with exactly: CLAUDE_SMOKE_OK"},
  {:gemini, "GEMINI_CLI_PATH", "Reply with exactly: GEMINI_SMOKE_OK"},
  {:codex, "CODEX_PATH", "Reply with exactly: CODEX_SMOKE_OK"}
]

maybe_model = fn
  opts, :claude -> put_opt.(opts, :model, System.get_env("ASM_CLAUDE_MODEL"))
  opts, :gemini -> put_opt.(opts, :model, System.get_env("ASM_GEMINI_MODEL"))
  opts, :codex -> put_opt.(opts, :model, System.get_env("ASM_CODEX_MODEL"))
  opts, _ -> opts
end

missing =
  Enum.filter(providers, fn {provider, env_var, _prompt} ->
    cli_path = System.get_env(env_var)

    case ASM.Provider.Resolver.resolve(provider, cli_path: cli_path) do
      {:ok, _} -> false
      {:error, _} -> true
    end
  end)

if missing != [] do
  IO.puts("missing CLI dependencies for smoke run:")

  Enum.each(missing, fn {provider, env_var, _prompt} ->
    IO.puts("- #{provider}: set #{env_var} or ensure CLI is available on PATH")
  end)

  System.halt(1)
end

Enum.each(providers, fn {provider, env_var, default_prompt} ->
  cli_path = System.get_env(env_var)
  prompt = "#{default_prompt} (provider=#{provider})"

  provider_opts =
    []
    |> put_opt.(:cli_path, cli_path)
    |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
    |> maybe_model.(provider)

  IO.puts("\n== Running #{provider} smoke ==")
  LiveSupport.ensure_cli!(provider, cli_path: cli_path)
  _ = LiveSupport.stream_and_collect!(provider, prompt, provider_opts)
end)

IO.puts("\nall provider smoke checks completed")

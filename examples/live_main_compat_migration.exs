Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport
alias ASM.Migration.MainCompat

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

unsupported_hints = [
  "AgentSessionManager.Adapters.AmpAdapter",
  "AgentSessionManager.Adapters.ShellAdapter"
]

Enum.each(unsupported_hints, fn hint ->
  case MainCompat.resolve_provider(hint) do
    {:error, error} ->
      IO.puts("[expected unsupported] #{hint}: #{Exception.message(error)}")

    {:ok, provider} ->
      IO.puts("[unexpected] #{hint} resolved to #{inspect(provider)}")
      System.halt(1)
  end
end)

providers = [
  {:claude, "CLAUDE_CLI_PATH", "ASM_CLAUDE_MODEL"},
  {:gemini, "GEMINI_CLI_PATH", "ASM_GEMINI_MODEL"},
  {:codex, "CODEX_PATH", "ASM_CODEX_MODEL"}
]

Enum.each(providers, fn {provider, cli_env, model_env} ->
  cli_path = System.get_env(cli_env)
  permission_mode = System.get_env("ASM_PERMISSION_MODE") || "auto"

  adapter_opts =
    []
    |> put_opt.(:model, System.get_env(model_env))
    |> put_opt.(:permission_mode, permission_mode)
    |> then(fn opts ->
      if provider == :codex do
        opts
        |> put_opt.(:working_directory, File.cwd!())
        |> put_opt.(:reasoning_effort, System.get_env("ASM_CODEX_REASONING"))
      else
        opts
      end
    end)

  input = %{
    messages: [
      %{role: "system", content: "Respond with exactly the requested token."},
      %{
        role: "user",
        content:
          "Reply with exactly: #{provider |> Atom.to_string() |> String.upcase()}_MIGRATION_OK"
      }
    ]
  }

  opts = [
    agent_id: "main-compat-#{provider}",
    metadata: %{source: "main_compat_example"},
    context: %{migration_example: true},
    tags: ["migration", "live"],
    adapter_opts: adapter_opts,
    event_callback: fn
      %{type: :message_streamed, data: %{delta: delta}} when is_binary(delta) ->
        IO.write(delta)

      _event ->
        :ok
    end
  ]

  IO.puts("\n== main compatibility migration check: #{provider} ==")
  LiveSupport.ensure_cli!(provider, Keyword.take([cli_path: cli_path], [:cli_path]))

  case MainCompat.run_once(provider, input, opts) do
    {:ok, result} ->
      IO.puts("\n[legacy result]")
      IO.puts("run_id=#{result.run_id}")
      IO.puts("session_id=#{result.session_id}")
      IO.puts("token_usage=#{inspect(result.token_usage)}")
      IO.puts("text=#{inspect(result.output.content)}")
      IO.puts("legacy_events=#{length(result.events)}")

    {:error, error} ->
      IO.puts("migration run failed: #{Exception.message(error)}")
      System.halt(1)
  end
end)

IO.puts("\nmain compatibility migration checks completed")

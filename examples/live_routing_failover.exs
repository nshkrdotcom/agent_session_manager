Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport
alias ASM.Extensions.Routing

provider_specs = [
  {:claude, "CLAUDE_CLI_PATH", "ASM_CLAUDE_MODEL"},
  {:gemini, "GEMINI_CLI_PATH", "ASM_GEMINI_MODEL"},
  {:codex, "CODEX_PATH", "ASM_CODEX_MODEL"}
]

available =
  provider_specs
  |> Enum.reduce([], fn {provider, env_var, model_env}, acc ->
    cli_path = System.get_env(env_var)

    with {:ok, _command_spec} <- ASM.Provider.Resolver.resolve(provider, cli_path: cli_path),
         {:ok, resolved_provider} <- ASM.Provider.resolve(provider) do
      [
        %{
          provider: resolved_provider.name,
          resolver_provider: provider,
          env_var: env_var,
          model_env: model_env
        }
        | acc
      ]
    else
      _ -> acc
    end
  end)
  |> Enum.reverse()

if length(available) < 2 do
  IO.puts("live routing failover requires at least two available provider CLIs.")
  IO.puts("set CLI paths and auth for at least two providers:")

  Enum.each(provider_specs, fn {provider, env_var, _model_env} ->
    IO.puts("- #{provider}: #{env_var}")
  end)

  System.halt(1)
end

[primary_spec, fallback_spec | _rest] = available

Enum.each([primary_spec, fallback_spec], fn %{
                                              resolver_provider: resolver_provider,
                                              env_var: env_var
                                            } ->
  LiveSupport.ensure_cli!(resolver_provider, cli_path: System.get_env(env_var))
end)

maybe_put = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

build_opts = fn env_var, model_env ->
  permission_mode = System.get_env("ASM_PERMISSION_MODE") || "auto"
  cli_path = System.get_env(env_var)
  model = System.get_env(model_env)

  []
  |> maybe_put.(:permission_mode, permission_mode)
  |> maybe_put.(:cli_path, cli_path)
  |> maybe_put.(:model, model)
end

unavailable_path =
  Path.join(
    System.tmp_dir!(),
    "asm-routing-missing-#{System.unique_integer([:positive])}"
  )

router =
  case Routing.start_router(
         providers: [
           [
             id: :simulated_unavailable,
             provider: primary_spec.provider,
             provider_opts:
               build_opts.(primary_spec.env_var, primary_spec.model_env)
               |> Keyword.put(:cli_path, unavailable_path)
           ],
           [
             id: :fallback_live,
             provider: fallback_spec.provider,
             provider_opts: build_opts.(fallback_spec.env_var, fallback_spec.model_env)
           ]
         ],
         failure_cooldown_ms: 30_000
       ) do
    {:ok, router} ->
      router

    {:error, error} ->
      IO.puts("failed to start router: #{Exception.message(error)}")
      System.halt(1)
  end

run_query = fn selection, prompt ->
  case ASM.query(selection.provider, prompt, selection.provider_opts) do
    {:ok, result} ->
      IO.puts(
        "provider=#{selection.provider} status=ok stop_reason=#{inspect(result.stop_reason)}"
      )

      {:ok, result}

    {:error, error} ->
      IO.puts("provider=#{selection.provider} status=error message=#{Exception.message(error)}")
      {:error, error}
  end
end

try do
  IO.puts("primary candidate uses an intentionally invalid CLI path to simulate outage")

  first =
    case Routing.select_provider(router) do
      {:ok, selection} ->
        selection

      {:error, error} ->
        IO.puts("selection failed: #{Exception.message(error)}")
        System.halt(1)
    end

  first_result =
    run_query.(
      first,
      "Reply with exactly: ROUTING_FAILOVER_PRIMARY_SHOULD_FAIL (provider=#{first.provider})"
    )

  case first_result do
    {:ok, _result} ->
      IO.puts("unexpected success for simulated unavailable provider")
      System.halt(1)

    {:error, _error} ->
      :ok
  end

  case Routing.report_result(router, first, first_result) do
    :ok ->
      :ok

    {:error, error} ->
      IO.puts("failed to report first result: #{Exception.message(error)}")
      System.halt(1)
  end

  second =
    case Routing.select_provider(router) do
      {:ok, selection} ->
        selection

      {:error, error} ->
        IO.puts("selection failed: #{Exception.message(error)}")
        System.halt(1)
    end

  second_result =
    run_query.(
      second,
      "Reply with exactly: ROUTING_FAILOVER_FALLBACK_OK (provider=#{second.provider})"
    )

  case Routing.report_result(router, second, second_result) do
    :ok ->
      :ok

    {:error, error} ->
      IO.puts("failed to report second result: #{Exception.message(error)}")
      System.halt(1)
  end

  case second_result do
    {:ok, _result} ->
      :ok

    {:error, _error} ->
      IO.puts("fallback provider failed; failover demo could not complete")
      System.halt(1)
  end

  {:ok, first_health} = Routing.provider_health(router, :simulated_unavailable)
  {:ok, second_health} = Routing.provider_health(router, :fallback_live)

  IO.puts("\nhealth after failover:")
  IO.puts("- simulated_unavailable: #{inspect(first_health)}")
  IO.puts("- fallback_live: #{inspect(second_health)}")
  IO.puts("\nrouting failover example completed")
after
  if Process.alive?(router), do: GenServer.stop(router)
end

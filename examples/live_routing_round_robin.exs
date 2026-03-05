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
  IO.puts("live routing round-robin requires at least two available provider CLIs.")

  Enum.each(provider_specs, fn {provider, env_var, _model_env} ->
    IO.puts("- #{provider}: set #{env_var} or ensure CLI is on PATH")
  end)

  System.halt(1)
end

selected_specs = Enum.take(available, 2)
selected_names = Enum.map(selected_specs, & &1.provider)

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

IO.puts("selected providers for round-robin: #{inspect(selected_names)}")

Enum.each(selected_specs, fn %{resolver_provider: resolver_provider, env_var: env_var} ->
  LiveSupport.ensure_cli!(resolver_provider, cli_path: System.get_env(env_var))
end)

router =
  case Routing.start_router(providers: selected_names) do
    {:ok, router} ->
      router

    {:error, error} ->
      IO.puts("failed to start router: #{Exception.message(error)}")
      System.halt(1)
  end

try do
  Enum.each(1..4, fn attempt ->
    selection =
      case Routing.select_provider(router) do
        {:ok, selection} ->
          selection

        {:error, error} ->
          IO.puts("selection failed: #{Exception.message(error)}")
          System.halt(1)
      end

    %{env_var: env_var, model_env: model_env} =
      Enum.find(selected_specs, fn spec -> spec.provider == selection.provider end)

    prompt = "Reply with exactly: ROUTE_ROUND_ROBIN_OK_#{attempt}_#{selection.provider}"
    opts = selection.provider_opts ++ build_opts.(env_var, model_env)

    IO.puts("\n[attempt #{attempt}] provider=#{selection.provider}")

    result =
      case ASM.query(selection.provider, prompt, opts) do
        {:ok, result} ->
          IO.puts("status=ok stop_reason=#{inspect(result.stop_reason)}")
          {:ok, result}

        {:error, error} ->
          IO.puts("status=error message=#{Exception.message(error)}")
          {:error, error}
      end

    case Routing.report_result(router, selection, result) do
      :ok ->
        :ok

      {:error, error} ->
        IO.puts("failed to report routing result: #{Exception.message(error)}")
        System.halt(1)
    end

    if match?({:error, _}, result), do: System.halt(1)
  end)

  IO.puts("\nrouting round-robin example completed")
after
  if Process.alive?(router), do: GenServer.stop(router)
end

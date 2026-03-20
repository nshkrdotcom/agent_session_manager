Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

put_opt = fn
  opts, _key, nil -> opts
  opts, _key, "" -> opts
  opts, key, value -> Keyword.put(opts, key, value)
end

parse_bool = fn
  value when value in ["1", "true", "TRUE", "yes", "YES", true] -> true
  _ -> false
end

tools =
  case System.get_env("ASM_AMP_TOOLS") do
    nil ->
      []

    "" ->
      []

    csv ->
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

opts =
  []
  |> put_opt.(:model, System.get_env("ASM_AMP_MODEL"))
  |> put_opt.(:mode, System.get_env("ASM_AMP_MODE") || "smart")
  |> put_opt.(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
  |> put_opt.(:include_thinking, parse_bool.(System.get_env("ASM_AMP_THINKING")))
  |> put_opt.(:tools, tools)
  |> put_opt.(:cli_path, System.get_env("AMP_CLI_PATH"))

prompt =
  LiveSupport.prompt_from_argv_or_default("Reply with exactly: AMP_OK")

IO.puts("running amp provider backend checks...")

with {:ok, provider} <- ASM.Provider.resolve(:amp),
     {:ok, core_resolution} <-
       ASM.ProviderRegistry.resolve(:amp, lane: :core, execution_mode: :local) do
  IO.puts("provider=#{provider.name} display_name=#{provider.display_name}")
  IO.puts("core_profile=#{inspect(provider.core_profile)}")
  IO.puts("sdk_runtime=#{inspect(provider.sdk_runtime)}")
  IO.puts("core_backend=#{inspect(core_resolution.backend)}")
  IO.puts("sdk_available?=#{inspect(core_resolution.sdk_available?)}")
else
  {:error, error} ->
    IO.puts("amp backend check failed: #{Exception.message(error)}")
    System.halt(1)
end

run_live? = parse_bool.(System.get_env("ASM_AMP_RUN_LIVE"))

if run_live? do
  LiveSupport.ensure_cli!(:amp, Keyword.take(opts, [:cli_path]))
  _ = LiveSupport.stream_and_collect!(:amp, prompt, opts)
else
  IO.puts("live run skipped (set ASM_AMP_RUN_LIVE=1 to run a live backend check)")
end

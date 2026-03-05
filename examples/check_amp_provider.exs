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

IO.puts("running amp provider contract checks...")

flags = ASM.Command.Amp.option_flags(opts)

if Keyword.get(opts, :permission_mode) in ["bypass", :bypass] and
     "--dangerously-allow-all" not in flags do
  IO.puts("amp command check failed: bypass mode did not map to --dangerously-allow-all")
  System.halt(1)
end

check_event = fn raw, expected_kind ->
  case ASM.Parser.Amp.parse(raw) do
    {:ok, {^expected_kind, _payload}} -> :ok
    {:ok, {kind, _payload}} -> raise "expected #{inspect(expected_kind)}, got #{inspect(kind)}"
    {:error, error} -> raise "amp parser check failed: #{Exception.message(error)}"
  end
end

check_event.(%{"type" => "message_streamed", "delta" => "amp-check"}, :assistant_delta)
check_event.(%{"type" => "tool_call_started", "tool_call_id" => "tool-1"}, :tool_use)
check_event.(%{"type" => "run_completed", "token_usage" => %{"input_tokens" => 1}}, :result)

IO.puts("amp command/parser checks passed")

run_live? = parse_bool.(System.get_env("ASM_AMP_RUN_LIVE"))

case ASM.Provider.Resolver.resolve(:amp, Keyword.take(opts, [:cli_path])) do
  {:ok, spec} ->
    IO.puts("amp cli resolved: #{spec.program}")

    if run_live? do
      _ = LiveSupport.stream_and_collect!(:amp, prompt, opts)
    else
      IO.puts("live run skipped (set ASM_AMP_RUN_LIVE=1 to run a live stream check)")
    end

  {:error, error} ->
    IO.puts("amp cli unavailable: #{Exception.message(error)}")

    if run_live? do
      IO.puts("ASM_AMP_RUN_LIVE=1 was requested, so this is a hard failure")
      System.halt(1)
    else
      IO.puts("live run skipped; parser/command contract checks completed")
    end
end

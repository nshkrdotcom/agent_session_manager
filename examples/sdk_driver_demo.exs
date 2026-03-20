Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport

{:ok, _apps} = Application.ensure_all_started(:agent_session_manager)

prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: SDK_LANE_OK")
session_id = "sdk-lane-demo-#{System.system_time(:millisecond)}"
cli_path = System.get_env("CLAUDE_CLI_PATH")

case ASM.ProviderRegistry.resolve(:claude, lane: :sdk, execution_mode: :local) do
  {:ok, resolution} ->
    IO.puts("resolved lane=#{resolution.lane} backend=#{inspect(resolution.backend)}")
    LiveSupport.ensure_cli!(:claude, cli_path: cli_path)

    with {:ok, session} <- ASM.start_session(session_id: session_id, provider: :claude) do
      try do
        events =
          ASM.stream(session, prompt,
            lane: :sdk,
            cli_path: cli_path
          )
          |> Enum.to_list()

        Enum.each(events, &LiveSupport.print_event/1)

        result = ASM.Stream.final_result(events)
        LiveSupport.print_result(result)
      after
        _ = ASM.stop_session(session)
      end
    else
      {:error, error} ->
        IO.puts("failed to start session: #{inspect(error)}")
        System.halt(1)
    end

  {:error, error} ->
    IO.puts("sdk lane unavailable: #{Exception.message(error)}")
    System.halt(1)
end

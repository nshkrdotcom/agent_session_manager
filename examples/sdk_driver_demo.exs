Code.require_file("live_support.exs", __DIR__)

alias ASM.Examples.LiveSupport
alias ASM.Message

{:ok, _apps} = Application.ensure_all_started(:agent_session_manager)

prompt = LiveSupport.prompt_from_argv_or_default("Reply with exactly: SDK_DRIVER_OK")
session_id = "sdk-driver-demo-#{System.system_time(:millisecond)}"

driver_opts = [
  stream_fun: fn _context ->
    [
      {:assistant_delta, %Message.Partial{content_type: :text, delta: "SDK_DRIVER_OK"}},
      {:result, %Message.Result{stop_reason: :end_turn, metadata: %{source: :sdk_demo}}}
    ]
  end
]

with {:ok, session} <- ASM.start_session(session_id: session_id, provider: :claude) do
  try do
    events =
      ASM.stream(session, prompt, driver: ASM.Stream.SDKDriver, driver_opts: driver_opts)
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

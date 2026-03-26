Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run ASM.start_session/1 and ASM.stream/3 against the selected provider.",
    "Reply with exactly: LIVE_STREAM_OK"
  )

session = ASM.Examples.Common.start_session!(config)

try do
  IO.puts("provider=#{config.provider}")
  IO.puts("session_id=#{ASM.session_id(session)}")
  IO.puts("prompt=#{inspect(config.prompt)}")
  IO.puts("")

  %{events: events, result: result} =
    ASM.Examples.Common.stream_to_result!(session, config.prompt)

  IO.puts("event_count=#{length(events)}")
  ASM.Examples.Common.print_result_summary(result)
after
  _ = ASM.stop_session(session)
end

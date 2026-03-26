Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Exercise ASM session lifecycle calls against the selected provider.",
    "Reply with exactly: LIVE_SESSION_STREAM_OK"
  )

query_prompt = "Reply with exactly: LIVE_SESSION_QUERY_OK"
session = ASM.Examples.Common.start_session!(config)

try do
  info = ASM.Examples.Common.session_info!(session)

  IO.puts("provider=#{config.provider}")
  IO.puts("session_id=#{info.session_id}")
  IO.puts("status=#{inspect(info.status)}")
  IO.puts("health_before=#{inspect(ASM.health(session))}")
  IO.puts("stream_prompt=#{inspect(config.prompt)}")
  IO.puts("")

  %{result: stream_result} = ASM.Examples.Common.stream_to_result!(session, config.prompt)
  ASM.Examples.Common.print_result_summary(stream_result, label: "stream")

  IO.puts("query_prompt=#{inspect(query_prompt)}")
  query_result = ASM.Examples.Common.query!(session, query_prompt)
  ASM.Examples.Common.print_result_summary(query_result, label: "query")

  IO.puts("health_after=#{inspect(ASM.health(session))}")
  IO.puts("session_cost=#{inspect(ASM.cost(session))}")
after
  _ = ASM.stop_session(session)
  IO.puts("health_stopped=#{inspect(ASM.health(session))}")
end

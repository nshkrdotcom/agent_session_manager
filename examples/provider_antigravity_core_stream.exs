Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run Antigravity CLI through ASM's core cli_subprocess_core lane.",
    "Reply with exactly: ANTIGRAVITY_CORE_OK"
  )

ASM.Examples.Common.assert_provider!(config, :antigravity)

session = ASM.Examples.Common.start_session!(config)

try do
  IO.puts("provider=#{config.provider}")
  IO.puts("session_id=#{ASM.session_id(session)}")
  IO.puts("prompt=#{inspect(config.prompt)}")
  IO.puts("")

  %{events: events, result: result} =
    ASM.Examples.Common.stream_to_result!(session, config.prompt)

  IO.puts("event_count=#{length(events)}")
  ASM.Examples.Common.print_result_summary(result, label: "antigravity_core")

  ASM.Examples.Common.assert_result_text_for_smoke!(config, result, "ANTIGRAVITY_CORE_OK",
    label: "antigravity core result"
  )
after
  _ = ASM.stop_session(session)
end

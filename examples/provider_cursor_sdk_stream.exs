Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run Cursor Agent CLI through ASM's SDK lane backed by cursor_cli_sdk.",
    "Reply with exactly: CURSOR_ASM_SDK_OK",
    provider_sdk?: true
  )

ASM.Examples.Common.assert_provider!(config, :cursor)
ASM.Examples.Common.ensure_provider_sdk_loaded!(:cursor, cli_path: Keyword.get(config.session_opts, :cli_path))

session = ASM.Examples.Common.start_session!(%{config | session_opts: Keyword.put(config.session_opts, :lane, :sdk)})

try do
  IO.puts("provider=#{config.provider}")
  IO.puts("session_id=#{ASM.session_id(session)}")
  IO.puts("prompt=#{inspect(config.prompt)}")
  IO.puts("")

  %{events: events, result: result} =
    ASM.Examples.Common.stream_to_result!(session, config.prompt)

  IO.puts("event_count=#{length(events)}")
  ASM.Examples.Common.print_result_summary(result, label: "cursor_sdk")

  ASM.Examples.Common.assert_result_text_for_smoke!(config, result, "CURSOR_ASM_SDK_OK",
    label: "cursor sdk result"
  )
after
  _ = ASM.stop_session(session)
end


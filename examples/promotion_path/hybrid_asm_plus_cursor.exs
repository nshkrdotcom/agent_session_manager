Code.require_file("../common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run a Cursor SDK prompt directly and then through ASM's SDK lane.",
    "Reply with exactly: CURSOR_HYBRID_OK",
    provider_sdk?: true
  )

ASM.Examples.Common.assert_provider!(config, :cursor)
ASM.Examples.Common.ensure_provider_sdk_loaded!(:cursor, cli_path: Keyword.get(config.session_opts, :cli_path))

sdk_result =
  case CursorCliSdk.run(config.prompt, %CursorCliSdk.Options{permission_mode: :bypass, timeout_ms: 120_000}) do
    {:ok, text} -> text
    {:error, error} -> raise "CursorCliSdk.run/2 failed: #{Exception.message(error)}"
  end

ASM.Examples.Common.assert_exact_text!(sdk_result, "CURSOR_HYBRID_OK",
  label: "cursor direct SDK result"
)

session =
  ASM.Examples.Common.start_session!(%{
    config
    | session_opts: Keyword.put(config.session_opts, :lane, :sdk)
  })

try do
  %{result: result} = ASM.Examples.Common.stream_to_result!(session, config.prompt)

  ASM.Examples.Common.assert_result_text_for_smoke!(config, result, "CURSOR_HYBRID_OK",
    label: "cursor ASM SDK result"
  )

  IO.puts("cursor_hybrid_direct=#{inspect(sdk_result)}")
  ASM.Examples.Common.print_result_summary(result, label: "cursor_hybrid_asm")
after
  _ = ASM.stop_session(session)
end


Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run a one-off ASM.query/3 call against the selected provider.",
    "Reply with exactly: LIVE_QUERY_OK"
  )

IO.puts("provider=#{config.provider}")
IO.puts("prompt=#{inspect(config.prompt)}")

result =
  ASM.Examples.Common.query!(
    config.provider,
    config.prompt,
    ASM.Examples.Common.query_opts(config)
  )

ASM.Examples.Common.print_result_summary(result)
ASM.Examples.Common.assert_result_text!(result, "LIVE_QUERY_OK", label: "live query result")

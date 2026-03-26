Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run GeminiCliSdk.execute/2 and GeminiCliSdk.resume_session/3 directly against Gemini's SDK surface.",
    "Reply with exactly: GEMINI_SDK_SESSION_OK",
    provider_sdk?: true
  )

ASM.Examples.Common.assert_provider!(config, :gemini)

ASM.Examples.Common.ensure_provider_sdk_loaded!(:gemini,
  sdk_root: config.sdk_root,
  cli_path: Keyword.get(config.session_opts, :cli_path)
)

gemini_sdk = Module.concat(["GeminiCliSdk"])
options_module = Module.concat(["GeminiCliSdk", "Options"])

options =
  struct!(options_module, %{
    model: Keyword.get(config.session_opts, :model),
    timeout_ms: 120_000
  })

events =
  config.prompt
  |> then(&apply(gemini_sdk, :execute, [&1, options]))
  |> Enum.to_list()

session_id =
  Enum.find_value(events, fn
    %{session_id: session_id} when is_binary(session_id) and session_id != "" -> session_id
    _other -> nil
  end)

if not is_binary(session_id) or session_id == "" do
  raise "GeminiCliSdk.execute/2 did not yield a session id"
end

resume_events =
  apply(gemini_sdk, :resume_session, [
    session_id,
    options,
    "Reply with exactly: GEMINI_SDK_RESUME_OK"
  ])
  |> Enum.to_list()

resume_result = List.last(resume_events)

IO.puts("provider=gemini")
IO.puts("session_id=#{session_id}")
IO.puts("initial_event_count=#{length(events)}")
IO.puts("resume_event_count=#{length(resume_events)}")
IO.puts("resume_result=#{inspect(resume_result)}")

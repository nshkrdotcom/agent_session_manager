Code.require_file("common.exs", __DIR__)

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run AmpSdk.execute/2 directly against Amp's provider-native SDK surface.",
    "Reply with exactly: AMP_SDK_STREAM_OK",
    provider_sdk?: true
  )

ASM.Examples.Common.assert_provider!(config, :amp)

ASM.Examples.Common.ensure_provider_sdk_loaded!(:amp,
  sdk_root: config.sdk_root,
  cli_path: Keyword.get(config.session_opts, :cli_path)
)

amp_sdk = Module.concat(["AmpSdk"])
options_module = Module.concat(["AmpSdk", "Types", "Options"])

options =
  struct!(options_module, %{
    cwd: Keyword.get(config.provider_opts, :cwd),
    mode: "smart",
    dangerously_allow_all:
      Keyword.get(config.provider_opts, :provider_permission_mode) == :dangerously_allow_all,
    thinking: false,
    no_ide: true,
    no_notifications: true
  })

messages =
  config.prompt
  |> then(&apply(amp_sdk, :execute, [&1, options]))
  |> Enum.to_list()

result_text =
  Enum.find_value(Enum.reverse(messages), fn
    %{result: result} when is_binary(result) -> result
    _other -> nil
  end)

last_message = List.last(messages)

if not is_binary(result_text) or result_text == "" do
  raise "AmpSdk.execute/2 did not yield a final result message"
end

IO.puts("provider=amp")
IO.puts("message_count=#{length(messages)}")
IO.puts("last_message_type=#{inspect(last_message && Map.get(last_message, :type))}")
IO.puts("result_text=#{inspect(result_text)}")

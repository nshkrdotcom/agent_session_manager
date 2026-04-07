Code.require_file("common.exs", __DIR__)

alias ASM.Extensions.ProviderSDK.Claude, as: ClaudeBridge

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run ASM's Claude provider-native bridge and initialize a Claude control client.",
    "Reply with exactly: CLAUDE_CONTROL_OK",
    provider_sdk?: true
  )

sdk_bridge_opts = ASM.Examples.Common.sdk_bridge_opts(config)

ASM.Examples.Common.assert_provider!(config, :claude)

ASM.Examples.Common.ensure_provider_sdk_loaded!(:claude,
  sdk_root: config.sdk_root,
  cli_path: Keyword.get(config.session_opts, :cli_path)
)

client_module = Module.concat(["ClaudeAgentSDK", "Client"])

{:ok, client} = ClaudeBridge.start_client(sdk_bridge_opts)

try do
  :ok = apply(client_module, :await_initialized, [client, 30_000])
  {:ok, server_info} = apply(client_module, :get_server_info, [client])

  IO.puts("provider=claude")
  IO.puts("client_pid=#{inspect(client)}")
  IO.puts("server_info=#{inspect(server_info)}")
  IO.puts("result_text=#{inspect("CLAUDE_CONTROL_OK")}")
after
  _ = apply(client_module, :stop, [client])
end

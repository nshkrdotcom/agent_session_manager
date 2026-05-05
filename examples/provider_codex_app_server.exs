Code.require_file("common.exs", __DIR__)

alias ASM.Extensions.ProviderSDK.Codex, as: CodexBridge

config =
  ASM.Examples.Common.example_config!(
    Path.basename(__ENV__.file),
    "Run ASM's Codex provider-native bridge and start a Codex app-server thread.",
    "Reply with exactly: CODEX_APP_SERVER_OK",
    provider_sdk?: true
  )

sdk_bridge_opts = ASM.Examples.Common.sdk_bridge_opts(config)
resolved_payload = ASM.Examples.Common.resolve_model_payload!(:codex, sdk_bridge_opts)

ASM.Examples.Common.assert_provider!(config, :codex)

ASM.Examples.Common.ensure_provider_sdk_loaded!(:codex,
  sdk_root: config.sdk_root,
  cli_path: Keyword.get(config.session_opts, :cli_path)
)

codex_module = :"Elixir.Codex"
app_server_module = :"Elixir.Codex.AppServer"

{:ok, conn} = CodexBridge.connect_app_server(sdk_bridge_opts, [], init_timeout_ms: 30_000)

try do
  {:ok, codex_opts} = CodexBridge.codex_options(sdk_bridge_opts)

  {:ok, thread_opts} =
    CodexBridge.thread_options(sdk_bridge_opts, transport: {:app_server, conn})

  {:ok, thread} = apply(codex_module, :start_thread, [codex_opts, thread_opts])

  ASM.Examples.Common.assert_exact_text!(
    codex_opts.model,
    Map.get(resolved_payload, :resolved_model),
    label: "Codex app-server resolved model"
  )

  if Map.get(resolved_payload, :provider_backend) == :oss do
    if codex_opts.model_payload.provider_backend != :oss do
      raise "Codex app-server did not preserve the OSS payload backend"
    end

    if codex_opts.model_payload.backend_metadata["oss_provider"] != "ollama" do
      raise "Codex app-server did not preserve the Ollama OSS provider"
    end
  end

  IO.puts("provider=codex")
  IO.puts("connection=#{inspect(conn)}")
  IO.puts("thread_id=#{inspect(Map.get(thread, :thread_id))}")
  IO.puts("thread_transport=#{inspect(Map.get(thread, :transport))}")
  IO.puts("result_text=#{inspect("CODEX_APP_SERVER_OK")}")
after
  _ = apply(app_server_module, :disconnect, [conn])
end

Code.require_file("common.exs", __DIR__)

defmodule ASM.Examples.LiveCodexAppServerSession do
  @moduledoc false

  alias ASM.Examples.Common

  @sentinel "ASM_CODEX_APP_SERVER_OK"
  @default_prompt """
  Reply with a short sentence that includes #{@sentinel}.
  """

  def main do
    config =
      Common.example_config!(
        Path.basename(__ENV__.file),
        "Run a live ASM Codex app-server session through the promoted SDK lane.",
        String.trim(@default_prompt),
        provider_sdk?: true
      )

    Common.assert_provider!(config, :codex)
    ensure_codex_sdk!(config)

    session = Common.start_session!(config)

    try do
      %{events: events, result: result} =
        Common.stream_to_result!(session, config.prompt, app_server_opts(config))

      assert_event!(events, :run_started)
      assert_event!(events, :result)
      assert_app_server_result!(result)
      assert_text_contains!(result.text, @sentinel, "Codex app-server response")

      Common.print_result_summary(result, label: "codex_app_server")
      IO.puts("codex_app_server_provider_session_id=#{provider_session_id!(result)}")
    after
      _ = ASM.stop_session(session)
    end
  end

  defp ensure_codex_sdk!(config) do
    Common.ensure_provider_sdk_loaded!(:codex,
      sdk_root: config.sdk_root,
      cli_path: Keyword.get(config.session_opts, :cli_path)
    )
  end

  defp app_server_opts(config) do
    [
      lane: :sdk,
      app_server: true,
      cwd: Keyword.get(config.session_opts, :cwd) || File.cwd!(),
      stream_timeout_ms: 120_000,
      backend_opts: [run_opts: [timeout_ms: 120_000]]
    ]
  end

  defp assert_app_server_result!(result) do
    metadata = result.metadata || %{}

    cond do
      metadata[:lane] != :sdk ->
        fail!("expected sdk lane metadata, got #{inspect(metadata[:lane])}")

      metadata[:runtime] != ASM.ProviderBackend.SDK.CodexAppServer ->
        fail!("expected Codex app-server runtime, got #{inspect(metadata[:runtime])}")

      :app_server not in Map.get(metadata, :capabilities, []) ->
        fail!("expected :app_server capability in result metadata")

      true ->
        :ok
    end
  end

  defp assert_event!(events, kind) do
    unless Enum.any?(events, &(&1.kind == kind)) do
      fail!("expected #{inspect(kind)} event, got #{inspect(Enum.map(events, & &1.kind))}")
    end
  end

  defp assert_text_contains!(text, sentinel, label) when is_binary(text) do
    unless String.contains?(text, sentinel) do
      fail!("#{label} missing #{sentinel}: #{inspect(text)}")
    end
  end

  defp assert_text_contains!(text, sentinel, label) do
    fail!("#{label} missing #{sentinel}: #{inspect(text)}")
  end

  defp provider_session_id!(result) do
    metadata = result.metadata || %{}
    provider_session_id = metadata[:provider_session_id] || result.session_id_from_cli

    case provider_session_id do
      value when is_binary(value) and value != "" -> value
      other -> fail!("missing provider_session_id in result metadata: #{inspect(other)}")
    end
  end

  defp fail!(message) do
    IO.puts(message)
    System.halt(1)
  end
end

ASM.Examples.LiveCodexAppServerSession.main()

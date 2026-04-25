Code.require_file("common.exs", __DIR__)

defmodule ASM.Examples.LiveCodexAppServerResume do
  @moduledoc false

  alias ASM.Examples.Common

  @context_phrase "ASM_RESUME_CONTEXT_20260425"
  @resume_sentinel "ASM_CODEX_APP_SERVER_RESUME_OK"
  @default_prompt """
  Remember this context phrase for the next turn: #{@context_phrase}.
  Reply with a short acknowledgement.
  """

  def main do
    config =
      Common.example_config!(
        Path.basename(__ENV__.file),
        "Run a live ASM Codex app-server turn, checkpoint the thread, then resume it.",
        String.trim(@default_prompt),
        provider_sdk?: true
      )

    Common.assert_provider!(config, :codex)
    ensure_codex_sdk!(config)

    session = Common.start_session!(config)

    try do
      first = Common.stream_to_result!(session, config.prompt, app_server_opts(config))
      first_thread_id = provider_session_id!(first.result)
      checkpoint = checkpoint_provider_session_id!(session)

      unless checkpoint == first_thread_id do
        fail!(
          "checkpoint #{inspect(checkpoint)} did not match first thread #{inspect(first_thread_id)}"
        )
      end

      resume_prompt =
        "What exact context phrase did I ask you to remember in the previous turn? " <>
          "Reply with that phrase and #{@resume_sentinel}."

      second =
        Common.stream_to_result!(
          session,
          resume_prompt,
          app_server_opts(config,
            continuation: %{strategy: :exact, provider_session_id: first_thread_id}
          )
        )

      second_thread_id = provider_session_id!(second.result)

      unless second_thread_id == first_thread_id do
        fail!(
          "resume used provider session #{inspect(second_thread_id)}, expected #{inspect(first_thread_id)}"
        )
      end

      assert_text_contains!(second.result.text, @context_phrase, "resumed Codex response")
      assert_text_contains!(second.result.text, @resume_sentinel, "resumed Codex response")

      Common.print_result_summary(first.result, label: "codex_app_server_resume_first")
      Common.print_result_summary(second.result, label: "codex_app_server_resume_second")

      IO.puts("""
      codex_app_server_resume_provider_session_id=#{first_thread_id}
      codex_app_server_resume_checkpoint=#{checkpoint}
      """)
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

  defp app_server_opts(config, extra \\ []) do
    [
      lane: :sdk,
      app_server: true,
      cwd: Keyword.get(config.session_opts, :cwd) || File.cwd!(),
      stream_timeout_ms: 120_000,
      backend_opts: [run_opts: [timeout_ms: 120_000]]
    ]
    |> Keyword.merge(extra)
  end

  defp checkpoint_provider_session_id!(session) do
    case ASM.checkpoint(session) do
      {:ok, %{provider_session_id: value}} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        fail!("missing checkpoint provider_session_id: #{inspect(other)}")

      {:error, error} ->
        fail!("failed to read checkpoint: #{inspect(error)}")
    end
  end

  defp provider_session_id!(result) do
    metadata = result.metadata || %{}
    provider_session_id = metadata[:provider_session_id] || result.session_id_from_cli

    case provider_session_id do
      value when is_binary(value) and value != "" -> value
      other -> fail!("missing provider_session_id in result metadata: #{inspect(other)}")
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

  defp fail!(message) do
    IO.puts(message)
    System.halt(1)
  end
end

ASM.Examples.LiveCodexAppServerResume.main()

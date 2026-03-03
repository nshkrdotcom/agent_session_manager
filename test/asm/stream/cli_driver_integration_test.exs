defmodule ASM.Stream.CLIDriverIntegrationTest do
  use ExUnit.Case, async: true

  test "codex stream does not rely on deprecated reasoning flag defaults" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      for arg in "$@"; do
        if [ "$arg" = "--reasoning-effort" ]; then
          echo "error: unexpected argument '--reasoning-effort' found"
          exit 2
        fi
      done

      echo '{"type":"thread.started","thread_id":"thread-1"}'
      echo '{"type":"turn.started"}'
      echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"CODEX_OK"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
      """)

    session_id = unique_session_id("codex")

    assert {:ok, session} =
             ASM.start_session(session_id: session_id, provider: :codex, cli_path: script)

    try do
      events =
        session
        |> ASM.stream("Reply with exactly: CODEX_OK", cli_path: script)
        |> Enum.to_list()

      refute Enum.any?(events, &(&1.kind == :error))
      result = ASM.Stream.final_result(events)
      assert result.text == "CODEX_OK"
      assert result.stop_reason == :end_turn
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "gemini stream tolerates non-json provider preamble lines" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      echo "Loaded cached credentials."
      echo '{"type":"message","role":"assistant","delta":true,"content":"GEMINI_OK"}'
      echo '{"type":"result","status":"completed","stats":{"input_tokens":1,"output_tokens":1}}'
      """)

    session_id = unique_session_id("gemini")

    assert {:ok, session} =
             ASM.start_session(session_id: session_id, provider: :gemini, cli_path: script)

    try do
      events =
        session
        |> ASM.stream("Reply with exactly: GEMINI_OK", cli_path: script)
        |> Enum.to_list()

      refute Enum.any?(events, &(&1.kind == :error))
      assert ASM.Stream.final_result(events).text == "GEMINI_OK"
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "multi-line diagnostic blobs do not trigger parse errors" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      echo "{"
      echo "  \\"error\\": \\"rate limited\\""
      echo "}"
      exit 2
      """)

    session_id = unique_session_id("diagnostic")

    assert {:ok, session} =
             ASM.start_session(session_id: session_id, provider: :gemini, cli_path: script)

    try do
      events =
        session
        |> ASM.stream("Reply with exactly: GEMINI_OK", cli_path: script)
        |> Enum.to_list()

      assert Enum.any?(events, &(&1.kind == :error))

      refute Enum.any?(events, fn event ->
               event.kind == :error and event.payload.kind == :parse_error
             end)

      error_event =
        Enum.find(events, fn event ->
          event.kind == :error and event.payload.kind == :transport_error
        end)

      assert error_event.payload.message =~ "status 2"
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "claude stream runs through PTY wrapper when provider requires tty-like execution" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      if [ ! -t 0 ]; then
        sleep 120
        exit 1
      fi

      echo '{"type":"assistant_delta","delta":"CLAUDE_OK"}'
      echo '{"type":"result","stop_reason":"end_turn"}'
      """)

    session_id = unique_session_id("claude-pty")

    assert {:ok, session} =
             ASM.start_session(session_id: session_id, provider: :claude, cli_path: script)

    try do
      events =
        session
        |> ASM.stream("Reply with exactly: CLAUDE_OK",
          cli_path: script,
          stream_timeout_ms: 20_000,
          transport_timeout_ms: 20_000
        )
        |> Enum.to_list()

      refute Enum.any?(events, &(&1.kind == :error))
      assert ASM.Stream.final_result(events).text == "CLAUDE_OK"
    after
      :ok = ASM.stop_session(session)
    end
  end

  defp write_script!(contents) do
    path = Path.join(System.tmp_dir!(), "asm-cli-driver-#{System.unique_integer([:positive])}.sh")
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp unique_session_id(prefix) do
    "#{prefix}-cli-driver-#{System.unique_integer([:positive])}"
  end
end

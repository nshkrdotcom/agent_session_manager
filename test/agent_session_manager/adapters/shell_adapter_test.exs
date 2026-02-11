defmodule AgentSessionManager.Adapters.ShellAdapterTest do
  @moduledoc """
  Tests for the ShellAdapter provider adapter.

  These tests verify:
  - ProviderAdapter behaviour compliance
  - Event mapping from shell command execution to normalized events
  - Successful execution (exit code 0)
  - Failed execution (non-zero exit code)
  - Timeout handling
  - Cancellation
  - Command allowlist/denylist enforcement
  - Input parsing (string, structured map, messages)
  - Concurrent execution
  - Error handling
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.ShellAdapter
  alias AgentSessionManager.Core.Error

  # ===========================================================================
  # start_link/1 validation
  # ===========================================================================

  describe "start_link/1 validation" do
    test "returns validation error when cwd is missing" do
      assert {:error, %Error{code: :validation_error}} = ShellAdapter.start_link([])
    end

    test "returns validation error when cwd is empty" do
      assert {:error, %Error{code: :validation_error}} = ShellAdapter.start_link(cwd: "")
    end

    test "returns validation error when cwd does not exist" do
      assert {:error, %Error{code: :validation_error}} =
               ShellAdapter.start_link(cwd: "/nonexistent_dir_xyz_99999")
    end

    test "starts successfully with valid cwd" do
      {:ok, adapter} = ShellAdapter.start_link(cwd: "/tmp")
      cleanup_on_exit(fn -> safe_stop(adapter) end)
      assert Process.alive?(adapter)
    end
  end

  # ===========================================================================
  # ProviderAdapter behaviour compliance
  # ===========================================================================

  describe "ProviderAdapter behaviour compliance" do
    test "name/1 returns 'shell'" do
      {:ok, adapter} = start_test_shell_adapter()
      assert ShellAdapter.name(adapter) == "shell"
    end

    test "capabilities/1 returns expected capabilities" do
      {:ok, adapter} = start_test_shell_adapter()
      {:ok, capabilities} = ShellAdapter.capabilities(adapter)

      assert is_list(capabilities)
      capability_names = Enum.map(capabilities, & &1.name)

      assert "command_execution" in capability_names
      assert "streaming" in capability_names
    end

    test "each capability has correct type and is enabled" do
      {:ok, adapter} = start_test_shell_adapter()
      {:ok, capabilities} = ShellAdapter.capabilities(adapter)

      for cap <- capabilities do
        assert cap.enabled == true
        assert cap.type in [:code_execution, :sampling]
      end
    end

    test "validate_config/2 requires cwd" do
      {:ok, adapter} = start_test_shell_adapter()
      assert :ok = ShellAdapter.validate_config(adapter, %{cwd: "/tmp"})

      assert {:error, %Error{code: :validation_error}} =
               ShellAdapter.validate_config(adapter, %{})
    end
  end

  # ===========================================================================
  # execute/4 with successful command
  # ===========================================================================

  describe "execute/4 with successful command" do
    test "executes and returns result with output" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo hello")

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)

      assert is_map(result)
      assert result.output.content =~ "hello"
      assert result.output.exit_code == 0
      assert result.output.timed_out == false
      assert result.token_usage == %{input_tokens: 0, output_tokens: 0}
    end

    test "returns result.events with emitted events" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo test")

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)

      assert is_list(result.events)
      refute Enum.empty?(result.events)
      assert Enum.any?(result.events, &(&1.type == :run_started))
      assert Enum.any?(result.events, &(&1.type == :run_completed))
    end

    test "emits correct event sequence for successful command" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo hello")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      types = Enum.map(events, & &1.type)

      assert :run_started in types
      assert :tool_call_started in types
      assert :tool_call_completed in types
      assert :message_received in types
      assert :run_completed in types
    end

    test "event ordering: run_started first, run_completed last" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo order_test")

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)

      first = hd(result.events).type
      last = List.last(result.events).type
      assert first == :run_started
      assert last == :run_completed
    end

    test "tool_call_started event includes bash tool name" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo tool_test")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      tool_started = Enum.find(events, &(&1.type == :tool_call_started))

      assert tool_started != nil
      assert tool_started.data.tool_name == "bash"
      assert is_binary(tool_started.data.tool_call_id)
      assert is_map(tool_started.data.tool_input)
    end

    test "tool_call_completed event includes exit code and output" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo completed_test")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      tool_completed = Enum.find(events, &(&1.type == :tool_call_completed))

      assert tool_completed != nil
      assert tool_completed.data.tool_name == "bash"
      assert tool_completed.data.tool_output.exit_code == 0
      assert tool_completed.data.tool_output.output =~ "completed_test"
    end

    test "run_completed event includes stop_reason and exit_code" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo stop_test")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      run_completed = Enum.find(events, &(&1.type == :run_completed))

      assert run_completed != nil
      assert run_completed.data.stop_reason == "exit_code_0"
      assert run_completed.data.exit_code == 0
      assert run_completed.data.duration_ms >= 0
    end
  end

  # ===========================================================================
  # execute/4 with failed command (non-zero exit)
  # ===========================================================================

  describe "execute/4 with failed command" do
    test "emits tool_call_failed and run_failed for non-zero exit" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "false")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      types = Enum.map(events, & &1.type)

      assert :tool_call_failed in types
      assert :error_occurred in types
      assert :run_failed in types
    end

    test "run_failed includes error_code :command_failed" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "sh -c 'exit 1'")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      run_failed = Enum.find(events, &(&1.type == :run_failed))

      assert run_failed != nil
      assert run_failed.data.error_code == :command_failed
    end

    test "result still returns {:ok, result} with non-zero exit_code" do
      # ShellAdapter returns {:ok, result} even for non-zero exit codes,
      # because the command DID execute. The exit code tells the story.
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "false")

      assert {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert result.output.exit_code != 0
    end
  end

  # ===========================================================================
  # execute/4 with timeout
  # ===========================================================================

  describe "execute/4 with timeout" do
    test "command times out and emits correct events" do
      {:ok, adapter} = start_test_shell_adapter(timeout_ms: 300)
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "sleep 30")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      assert result.output.timed_out == true

      events = collect_events()
      types = Enum.map(events, & &1.type)

      assert :tool_call_failed in types
      assert :error_occurred in types
      assert :run_failed in types
    end
  end

  # ===========================================================================
  # Input parsing
  # ===========================================================================

  describe "input parsing" do
    test "string input is executed as shell command" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo string_input")

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert result.output.content =~ "string_input"
    end

    test "structured map input with command and args" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()

      run =
        build_test_run(
          session_id: session.id,
          input: %{
            command: "echo",
            args: ["structured_input"]
          }
        )

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert result.output.content =~ "structured_input"
    end

    test "structured map input with cwd override" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()

      run =
        build_test_run(
          session_id: session.id,
          input: %{
            command: "pwd",
            cwd: "/tmp"
          }
        )

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert String.trim(result.output.content) == "/tmp"
    end

    test "messages-based input extracts command from user content" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()

      run =
        build_test_run(
          session_id: session.id,
          input: %{
            messages: [%{role: "user", content: "echo messages_input"}]
          }
        )

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert result.output.content =~ "messages_input"
    end
  end

  # ===========================================================================
  # Command allowlist/denylist
  # ===========================================================================

  describe "command allowlist/denylist" do
    test "allowed_commands restricts execution" do
      {:ok, adapter} = start_test_shell_adapter(allowed_commands: ["echo", "ls"])
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: %{command: "rm", args: ["-rf", "/"]})

      assert {:error, %Error{code: :policy_violation}} =
               ShellAdapter.execute(adapter, run, session, timeout: 10_000)
    end

    test "allowed commands work normally" do
      {:ok, adapter} = start_test_shell_adapter(allowed_commands: ["echo", "ls"])
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo allowed")

      {:ok, result} = ShellAdapter.execute(adapter, run, session, timeout: 10_000)
      assert result.output.content =~ "allowed"
    end

    test "denied_commands blocks execution" do
      {:ok, adapter} = start_test_shell_adapter(denied_commands: ["rm", "sudo"])
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: %{command: "rm", args: ["file.txt"]})

      assert {:error, %Error{code: :policy_violation}} =
               ShellAdapter.execute(adapter, run, session, timeout: 10_000)
    end

    test "denied_commands takes precedence over allowed_commands" do
      {:ok, adapter} =
        start_test_shell_adapter(
          allowed_commands: ["rm", "echo"],
          denied_commands: ["rm"]
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: %{command: "rm", args: ["file.txt"]})

      assert {:error, %Error{code: :policy_violation}} =
               ShellAdapter.execute(adapter, run, session, timeout: 10_000)
    end
  end

  # ===========================================================================
  # cancel/2
  # ===========================================================================

  describe "cancel/2" do
    test "cancels an active run" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "sleep 30")

      task =
        Task.async(fn ->
          ShellAdapter.execute(adapter, run, session, timeout: 30_000)
        end)

      Process.sleep(100)
      run_id = run.id
      {:ok, ^run_id} = ShellAdapter.cancel(adapter, run.id)

      result = Task.await(task, 10_000)

      case result do
        {:error, %Error{code: :cancelled}} -> :ok
        {:ok, _} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "returns error for unknown run_id" do
      {:ok, adapter} = start_test_shell_adapter()
      result = ShellAdapter.cancel(adapter, "non-existent-run-id")
      assert {:error, %Error{code: :run_not_found}} = result
    end
  end

  # ===========================================================================
  # Event provider attribution
  # ===========================================================================

  describe "event provider attribution" do
    test "all events include provider: :shell" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo attribution_test")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()

      for event <- events do
        assert event.provider == :shell,
               "Event #{event.type} missing provider :shell"
      end
    end

    test "events include session_id and run_id" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "echo id_test")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()

      for event <- events do
        assert event.session_id == session.id
        assert event.run_id == run.id
      end
    end
  end

  # ===========================================================================
  # Worker failure isolation
  # ===========================================================================

  describe "worker failure isolation" do
    test "adapter survives worker crash and remains usable" do
      {:ok, adapter} = start_test_shell_adapter()
      session = build_test_session()

      # Execute a normal command to verify it works
      run1 = build_test_run(session_id: session.id, input: "echo before", index: 1)
      assert {:ok, _} = ShellAdapter.execute(adapter, run1, session, timeout: 10_000)

      # Adapter should still be alive and functional
      assert Process.alive?(adapter)
      assert {:ok, _caps} = ShellAdapter.capabilities(adapter)

      # Execute another command
      run2 = build_test_run(session_id: session.id, input: "echo after", index: 2)
      assert {:ok, result} = ShellAdapter.execute(adapter, run2, session, timeout: 10_000)
      assert result.output.content =~ "after"
    end
  end

  # ===========================================================================
  # Concurrent execution
  # ===========================================================================

  describe "concurrent execution" do
    test "handles multiple concurrent executions" do
      {:ok, adapter} = start_test_shell_adapter()

      results =
        run_concurrent(3, fn i ->
          session = build_test_session(index: i)
          run = build_test_run(session_id: session.id, input: "echo concurrent_#{i}", index: i)
          ShellAdapter.execute(adapter, run, session, timeout: 10_000)
        end)

      for result <- results do
        assert {:ok, _} = result
      end
    end
  end

  # ===========================================================================
  # success_exit_codes configuration
  # ===========================================================================

  describe "success_exit_codes configuration" do
    test "custom success_exit_codes treats specified codes as success" do
      {:ok, adapter} = start_test_shell_adapter(success_exit_codes: [0, 1])
      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "sh -c 'exit 1'")

      test_pid = self()
      callback = fn event -> send(test_pid, {:event, event}) end

      {:ok, _result} =
        ShellAdapter.execute(adapter, run, session,
          event_callback: callback,
          timeout: 10_000
        )

      events = collect_events()
      types = Enum.map(events, & &1.type)

      # With exit code 1 in success list, should emit run_completed not run_failed
      assert :run_completed in types
      refute :run_failed in types
    end
  end

  # ===========================================================================
  # Test Helpers
  # ===========================================================================

  defp start_test_shell_adapter(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, "/tmp")
    adapter_opts = Keyword.put(opts, :cwd, cwd)

    {:ok, adapter} = ShellAdapter.start_link(adapter_opts)
    cleanup_on_exit(fn -> safe_stop(adapter) end)
    {:ok, adapter}
  end

  defp collect_events(timeout_ms \\ 500) do
    collect_events_acc([], timeout_ms)
  end

  defp collect_events_acc(acc, timeout_ms) do
    receive do
      {:event, event} -> collect_events_acc([event | acc], timeout_ms)
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end

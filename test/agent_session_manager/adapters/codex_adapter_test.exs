defmodule AgentSessionManager.Adapters.CodexAdapterTest do
  @moduledoc """
  Tests for the CodexAdapter provider adapter.

  These tests verify:
  - ProviderAdapter behaviour compliance
  - Event mapping from Codex events to normalized events
  - Streaming execution
  - Tool call handling
  - Cancellation
  - Error handling
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.CodexAdapter
  alias AgentSessionManager.Core.{Error, Transcript}
  alias AgentSessionManager.Test.CodexMockSDK

  defmodule FailingMockCodexSDK do
    @moduledoc false

    def run_streamed(_sdk_pid, _thread, _input, _opts) do
      raise "boom in run_streamed"
    end
  end

  defmodule CapturingPromptSDK do
    @moduledoc false

    alias Codex.Events

    def run_streamed(test_pid, _thread, input, _opts) do
      send(test_pid, {:captured_prompt, input})

      events = [
        %Events.ThreadStarted{thread_id: "thread-1", metadata: %{}},
        %Events.ItemAgentMessageDelta{
          thread_id: "thread-1",
          turn_id: "turn-1",
          item: %{"content" => [%{"type" => "text", "text" => "ok"}]}
        },
        %Events.ThreadTokenUsageUpdated{
          thread_id: "thread-1",
          turn_id: "turn-1",
          usage: %{"input_tokens" => 1, "output_tokens" => 1}
        },
        %Events.TurnCompleted{
          thread_id: "thread-1",
          turn_id: "turn-1",
          status: "completed",
          usage: %{"input_tokens" => 1, "output_tokens" => 1}
        }
      ]

      {:ok, %{raw_events_fn: fn -> events end}}
    end

    def raw_events(%{raw_events_fn: fun}), do: fun.()
    def cancel(_pid), do: :ok
  end

  describe "start_link/1 validation" do
    test "returns validation error when working_directory is missing" do
      assert {:error, %Error{code: :validation_error, message: "working_directory is required"}} =
               CodexAdapter.start_link([])
    end

    test "returns validation error when working_directory is empty" do
      assert {:error,
              %Error{code: :validation_error, message: "working_directory cannot be empty"}} =
               CodexAdapter.start_link(working_directory: "")
    end
  end

  describe "ProviderAdapter behaviour compliance" do
    test "name/1 returns 'codex'" do
      {:ok, adapter} = start_test_adapter()
      assert CodexAdapter.name(adapter) == "codex"
    end

    test "capabilities/1 returns expected capabilities" do
      {:ok, adapter} = start_test_adapter()
      {:ok, capabilities} = CodexAdapter.capabilities(adapter)

      assert is_list(capabilities)
      capability_names = Enum.map(capabilities, & &1.name)

      assert "streaming" in capability_names
      assert "tool_use" in capability_names
      assert "interrupt" in capability_names
    end

    test "validate_config/2 requires working_directory" do
      {:ok, adapter} = start_test_adapter()

      assert :ok = CodexAdapter.validate_config(adapter, %{working_directory: "/tmp"})

      assert {:error, %Error{code: :validation_error}} =
               CodexAdapter.validate_config(adapter, %{})
    end

    test "validate_config/2 accepts optional model" do
      {:ok, adapter} = start_test_adapter()

      assert :ok =
               CodexAdapter.validate_config(adapter, %{
                 working_directory: "/tmp",
                 model: "claude-haiku-4-5-20251001"
               })
    end
  end

  describe "execute/4 with simple response" do
    test "executes and returns result with output" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

      assert is_map(result)
      assert Map.has_key?(result, :output)
      assert result.output.content =~ "Test response"
    end

    test "returns result.events with emitted events" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

      assert is_list(result.events)
      refute Enum.empty?(result.events)
      assert Enum.any?(result.events, &(&1.type == :run_started))
      assert Enum.any?(result.events, &(&1.type == :run_completed))
    end

    test "emits events via callback" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      test_pid = self()

      event_callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: event_callback,
          timeout: 5_000
        )

      # Collect events
      events = collect_events()

      # Verify event types
      event_types = Enum.map(events, & &1.type)

      assert :run_started in event_types
      assert :message_streamed in event_types or :message_received in event_types
      assert :token_usage_updated in event_types
      assert :run_completed in event_types
    end

    test "run_started event includes thread_id" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      run_started = Enum.find(events, &(&1.type == :run_started))

      assert run_started != nil
      assert run_started.data.thread_id != nil
      assert run_started.provider == :codex
    end
  end

  describe "execute/4 with streaming" do
    test "emits multiple message_streamed events" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :streaming,
          chunks: ["Hello", " ", "world", "!"]
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Stream test")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      streamed_events = Enum.filter(events, &(&1.type == :message_streamed))

      # Should have multiple streaming events
      assert length(streamed_events) >= 2
    end

    test "message_streamed events include delta content" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :streaming,
          chunks: ["Part 1", "Part 2"]
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Stream test")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      streamed_events = Enum.filter(events, &(&1.type == :message_streamed))

      deltas = Enum.map(streamed_events, & &1.data.delta)
      assert "Part 1" in deltas or Enum.any?(deltas, &String.contains?(&1, "Part"))
    end
  end

  describe "execute/4 with tool calls" do
    test "emits tool_call_started and tool_call_completed events" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_name: "read_file",
          tool_args: %{"path" => "/test.txt"}
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Read a file")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      event_types = Enum.map(events, & &1.type)

      assert :tool_call_started in event_types
      assert :tool_call_completed in event_types
    end

    test "tool_call_started includes canonical tool fields" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_name: "write_file",
          tool_args: %{"path" => "/output.txt", "content" => "Hello"}
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Write a file")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      tool_started = Enum.find(events, &(&1.type == :tool_call_started))

      assert tool_started != nil
      assert tool_started.data.tool_name == "write_file"
      assert tool_started.data.tool_call_id != nil
      assert tool_started.data.tool_input == %{"path" => "/output.txt", "content" => "Hello"}
    end

    test "tool_call_completed includes canonical tool output fields" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_output: %{"result" => "file written successfully"}
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Write")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      tool_completed = Enum.find(events, &(&1.type == :tool_call_completed))

      assert tool_completed != nil
      assert tool_completed.data.tool_call_id != nil
      assert tool_completed.data.tool_output["result"] == "file written successfully"
    end

    test "result includes tool_calls in output" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_name: "bash",
          call_id: "call-123"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Run command")

      {:ok, result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

      assert [tool_call | _] = result.output.tool_calls
      assert tool_call.name == "bash"
      assert tool_call.id == "call-123"
    end
  end

  describe "execute/4 with token usage" do
    test "emits token_usage_updated events" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      usage_events = Enum.filter(events, &(&1.type == :token_usage_updated))

      assert [first_usage | _] = usage_events

      usage = first_usage.data
      assert Map.has_key?(usage, :input_tokens)
      assert Map.has_key?(usage, :output_tokens)
    end

    test "result includes token_usage" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      {:ok, result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

      assert Map.has_key?(result, :token_usage)
      assert result.token_usage.input_tokens >= 0
      assert result.token_usage.output_tokens >= 0
    end
  end

  describe "execute/4 error handling" do
    test "returns error for failed turn" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :error,
          error_message: "API rate limit exceeded"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      result = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

      assert {:error, %Error{}} = result
    end

    test "emits error_occurred and run_failed events on error" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :error,
          error_message: "Connection failed"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      CodexAdapter.execute(adapter, run, session,
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        timeout: 5_000
      )

      events = collect_events()
      event_types = Enum.map(events, & &1.type)

      assert :error_occurred in event_types or :run_failed in event_types
    end
  end

  describe "cancel/2" do
    test "cancels an active run" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :streaming,
          delay_ms: 100,
          chunks: Enum.map(1..20, &"chunk-#{&1}")
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Long running")

      # Start execution in a task
      task =
        Task.async(fn ->
          CodexAdapter.execute(adapter, run, session, timeout: 30_000)
        end)

      # Give it time to start
      Process.sleep(50)

      # Cancel the run
      run_id = run.id
      {:ok, ^run_id} = CodexAdapter.cancel(adapter, run.id)

      # The task should complete (either with error or partial result)
      result = Task.await(task, 5_000)

      # Should either be cancelled error or partial success
      case result do
        {:error, %Error{code: :cancelled}} -> :ok
        {:ok, _} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "returns error for unknown run_id" do
      {:ok, adapter} = start_test_adapter()

      result = CodexAdapter.cancel(adapter, "non-existent-run-id")

      assert {:error, %Error{code: :run_not_found}} = result
    end
  end

  describe "worker failure isolation" do
    test "returns internal_error and keeps adapter alive" do
      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: FailingMockCodexSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      assert {:error, %Error{code: :internal_error}} = CodexAdapter.execute(adapter, run, session)
      assert Process.alive?(adapter)
      assert {:ok, _caps} = CodexAdapter.capabilities(adapter)
    end
  end

  describe "event provider attribution" do
    test "all events include provider: :codex" do
      {:ok, adapter} = start_test_adapter(scenario: :with_tool_call)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()

      for event <- events do
        assert event.provider == :codex,
               "Event #{event.type} missing provider :codex"
      end
    end

    test "events include session_id and run_id" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      {:ok, _result} =
        CodexAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()

      for event <- events do
        assert event.session_id == session.id
        assert event.run_id == run.id
      end
    end
  end

  describe "transcript continuity input" do
    test "replays transcript context in prompt when session transcript is present" do
      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CapturingPromptSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      session =
        build_test_session(
          context: %{
            transcript: %Transcript{
              session_id: "ses-transcript",
              messages: [
                %{
                  role: :assistant,
                  content: "Earlier assistant reply",
                  tool_call_id: nil,
                  tool_name: nil,
                  tool_input: nil,
                  tool_output: nil,
                  metadata: %{}
                }
              ],
              last_sequence: 3,
              last_timestamp: DateTime.utc_now(),
              metadata: %{}
            }
          }
        )

      run = build_test_run(session_id: session.id, input: "Current question")

      assert {:ok, _result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)
      assert_receive {:captured_prompt, prompt}, 1_000
      assert is_binary(prompt)
      assert prompt =~ "Earlier assistant reply"
      assert prompt =~ "Current question"
    end
  end

  describe "concurrent execution" do
    test "handles multiple concurrent executions" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      results =
        run_concurrent(3, fn i ->
          session = build_test_session()
          run = build_test_run(session_id: session.id, input: "Request #{i}")

          CodexAdapter.execute(adapter, run, session, timeout: 5_000)
        end)

      for result <- results do
        assert {:ok, _} = result
      end
    end
  end

  # ============================================================================
  # Permission Mode Configuration Tests
  # ============================================================================

  describe "permission_mode configuration" do
    test "stores permission_mode in adapter state" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          permission_mode: :full_auto,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.permission_mode == :full_auto
    end

    test "defaults permission_mode to nil when not provided" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.permission_mode == nil
    end

    test "full_auto produces thread options with full_auto: true" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          permission_mode: :full_auto,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.full_auto == true
      assert thread_opts.dangerously_bypass_approvals_and_sandbox == false
    end

    test "dangerously_skip_permissions produces thread options with dangerously bypass" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          permission_mode: :dangerously_skip_permissions,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.dangerously_bypass_approvals_and_sandbox == true
    end

    test "default permission_mode leaves thread options at defaults" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.full_auto == false
      assert thread_opts.dangerously_bypass_approvals_and_sandbox == false
    end

    test "accept_edits is a no-op for codex (no equivalent)" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          permission_mode: :accept_edits,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.full_auto == false
      assert thread_opts.dangerously_bypass_approvals_and_sandbox == false
    end
  end

  describe "max_turns configuration" do
    test "defaults max_turns to nil in adapter state" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.max_turns == nil
    end

    test "stores explicit max_turns in adapter state" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          max_turns: 20,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.max_turns == 20
    end

    test "default max_turns produces empty run options (SDK default of 10 applies)" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      run_opts = CodexAdapter.build_run_options_for_state(state)
      assert run_opts == %{}
    end

    test "explicit max_turns is included in run options" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          max_turns: 25,
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      run_opts = CodexAdapter.build_run_options_for_state(state)
      assert run_opts == %{max_turns: 25}
    end
  end

  describe "sdk_opts passthrough" do
    test "defaults sdk_opts to empty list in adapter state" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.sdk_opts == []
    end

    test "sdk_opts fields are merged into thread options" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          sdk_opts: [web_search_mode: :live, show_raw_agent_reasoning: true],
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.web_search_mode == :live
      assert thread_opts.show_raw_agent_reasoning == true
    end

    test "normalized options take precedence over sdk_opts" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          permission_mode: :full_auto,
          sdk_opts: [full_auto: false],
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      # Normalized permission_mode should win over sdk_opts
      assert thread_opts.full_auto == true
    end

    test "system_prompt is mapped to base_instructions in thread options" do
      {:ok, mock_sdk} = CodexMockSDK.start_link(scenario: :simple_response)
      cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

      {:ok, adapter} =
        CodexAdapter.start_link(
          working_directory: "/tmp/test",
          system_prompt: "You are a code reviewer.",
          sdk_module: CodexMockSDK,
          sdk_pid: mock_sdk
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      {:ok, thread_opts} = CodexAdapter.build_thread_options_for_state(state)
      assert thread_opts.base_instructions == "You are a code reviewer."
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp start_test_adapter(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :simple_response)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    chunks = Keyword.get(opts, :chunks)
    tool_name = Keyword.get(opts, :tool_name)
    tool_args = Keyword.get(opts, :tool_args)
    tool_output = Keyword.get(opts, :tool_output)
    call_id = Keyword.get(opts, :call_id)
    error_message = Keyword.get(opts, :error_message)

    # Build mock SDK options
    mock_opts =
      [scenario: scenario, delay_ms: delay_ms]
      |> maybe_add(:chunks, chunks)
      |> maybe_add(:tool_name, tool_name)
      |> maybe_add(:tool_args, tool_args)
      |> maybe_add(:tool_output, tool_output)
      |> maybe_add(:call_id, call_id)
      |> maybe_add(:error_message, error_message)

    {:ok, mock_sdk} = CodexMockSDK.start_link(mock_opts)
    cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

    # Start adapter with mock SDK
    {:ok, adapter} =
      CodexAdapter.start_link(
        working_directory: "/tmp/test",
        sdk_module: CodexMockSDK,
        sdk_pid: mock_sdk
      )

    cleanup_on_exit(fn -> safe_stop(adapter) end)

    {:ok, adapter}
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp collect_events(timeout_ms \\ 200) do
    collect_events_acc([], timeout_ms)
  end

  defp collect_events_acc(acc, timeout_ms) do
    receive do
      {:event, event} ->
        collect_events_acc([event | acc], timeout_ms)
    after
      timeout_ms ->
        Enum.reverse(acc)
    end
  end
end

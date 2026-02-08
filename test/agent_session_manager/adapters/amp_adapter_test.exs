defmodule AgentSessionManager.Adapters.AmpAdapterTest do
  @moduledoc """
  Tests for the AmpAdapter provider adapter.

  These tests verify:
  - ProviderAdapter behaviour compliance
  - Event mapping from amp_sdk messages to normalized events
  - Streaming execution
  - Tool call handling
  - Cancellation
  - Error handling
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.AmpAdapter
  alias AgentSessionManager.Core.{Error, Transcript}
  alias AgentSessionManager.Test.AmpMockSDK

  defmodule FailingMockAmpSDK do
    @moduledoc false

    def execute(_sdk_pid, _prompt, _opts) do
      raise "boom in execute"
    end
  end

  defmodule CapturingPromptSDK do
    @moduledoc false

    alias AgentSessionManager.Test.AmpMockSDK

    def execute(test_pid, prompt, _opts) do
      send(test_pid, {:captured_prompt, prompt})
      AmpMockSDK.build_event_stream(:simple_response)
    end

    def cancel(_pid), do: :ok
  end

  describe "start_link/1 validation" do
    test "returns validation error when cwd is missing" do
      assert {:error, %Error{code: :validation_error, message: "cwd is required"}} =
               AmpAdapter.start_link([])
    end

    test "returns validation error when cwd is empty" do
      assert {:error, %Error{code: :validation_error, message: "cwd cannot be empty"}} =
               AmpAdapter.start_link(cwd: "")
    end
  end

  describe "ProviderAdapter behaviour compliance" do
    test "name/1 returns 'amp'" do
      {:ok, adapter} = start_test_adapter()
      assert AmpAdapter.name(adapter) == "amp"
    end

    test "capabilities/1 returns expected capabilities" do
      {:ok, adapter} = start_test_adapter()
      {:ok, capabilities} = AmpAdapter.capabilities(adapter)

      assert is_list(capabilities)
      capability_names = Enum.map(capabilities, & &1.name)

      assert "streaming" in capability_names
      assert "tool_use" in capability_names
      assert "interrupt" in capability_names
      assert "mcp" in capability_names
      assert "file_operations" in capability_names
      assert "bash" in capability_names
    end

    test "each capability has correct type and is enabled" do
      {:ok, adapter} = start_test_adapter()
      {:ok, capabilities} = AmpAdapter.capabilities(adapter)

      for cap <- capabilities do
        assert cap.enabled == true
        assert cap.type in [:sampling, :tool]
      end
    end

    test "validate_config/2 requires cwd" do
      {:ok, adapter} = start_test_adapter()

      assert :ok = AmpAdapter.validate_config(adapter, %{cwd: "/tmp"})

      assert {:error, %Error{code: :validation_error}} =
               AmpAdapter.validate_config(adapter, %{})
    end

    test "validate_config/2 rejects empty cwd" do
      {:ok, adapter} = start_test_adapter()

      assert {:error, %Error{code: :validation_error}} =
               AmpAdapter.validate_config(adapter, %{cwd: ""})
    end
  end

  describe "execute/4 with simple response" do
    test "executes and returns result with output" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      assert is_map(result)
      assert Map.has_key?(result, :output)
      assert result.output.content =~ "Test response"
    end

    test "returns result.events with emitted events" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

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
        AmpAdapter.execute(adapter, run, session,
          event_callback: event_callback,
          timeout: 5_000
        )

      events = collect_events()

      event_types = Enum.map(events, & &1.type)

      assert :run_started in event_types
      assert :message_streamed in event_types or :message_received in event_types
      assert :token_usage_updated in event_types
      assert :run_completed in event_types
    end

    test "run_started event includes session_id and tools" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      run_started = Enum.find(events, &(&1.type == :run_started))

      assert run_started != nil
      assert run_started.data.session_id != nil
      assert run_started.provider == :amp
    end

    test "event ordering: run_started first, run_completed last" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      first = hd(result.events).type
      last = List.last(result.events).type

      assert first == :run_started
      assert last == :run_completed
    end

    test "result.output.content matches accumulated text" do
      {:ok, adapter} =
        start_test_adapter(scenario: :simple_response, content: "Expected output")

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      assert result.output.content == "Expected output"
    end

    test "result.token_usage has input_tokens and output_tokens" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      assert Map.has_key?(result, :token_usage)
      assert result.token_usage.input_tokens >= 0
      assert result.token_usage.output_tokens >= 0
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
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      streamed_events = Enum.filter(events, &(&1.type == :message_streamed))

      assert length(streamed_events) >= 2
    end

    test "content accumulates correctly across chunks" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :streaming,
          chunks: ["Part 1", " Part 2"]
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Stream test")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      assert result.output.content == "Part 1 Part 2"
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
        AmpAdapter.execute(adapter, run, session,
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
          tool_input: %{"path" => "/test.txt"}
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Read a file")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
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
          tool_id: "tool-use-42",
          tool_input: %{"path" => "/output.txt", "content" => "Hello"}
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Write a file")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      tool_started = Enum.find(events, &(&1.type == :tool_call_started))

      assert tool_started != nil
      assert tool_started.data.tool_name == "write_file"
      assert tool_started.data.tool_call_id == "tool-use-42"
      assert tool_started.data.tool_input == %{"path" => "/output.txt", "content" => "Hello"}
    end

    test "tool_call_completed includes canonical tool output fields" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_id: "tool-use-99",
          tool_output: "file written successfully"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Write")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      tool_completed = Enum.find(events, &(&1.type == :tool_call_completed))

      assert tool_completed != nil
      assert tool_completed.data.tool_call_id == "tool-use-99"
      assert tool_completed.data.tool_output == "file written successfully"
    end

    test "tool_call_failed when tool result has is_error: true" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_is_error: true,
          tool_output: "Permission denied"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Do something")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      event_types = Enum.map(events, & &1.type)
      tool_failed = Enum.find(events, &(&1.type == :tool_call_failed))

      assert :tool_call_failed in event_types
      assert tool_failed != nil
      assert is_binary(tool_failed.data.tool_call_id)
      assert tool_failed.data.tool_output == "Permission denied"
    end

    test "result includes tool_calls in output" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :with_tool_call,
          tool_name: "bash",
          tool_id: "call-123"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Run command")

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

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
        AmpAdapter.execute(adapter, run, session,
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

      {:ok, result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

      assert Map.has_key?(result, :token_usage)
      assert result.token_usage.input_tokens >= 0
      assert result.token_usage.output_tokens >= 0
    end
  end

  describe "execute/4 error handling" do
    test "returns error for ErrorResultMessage" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :error,
          error_message: "API rate limit exceeded"
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      result = AmpAdapter.execute(adapter, run, session, timeout: 5_000)

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

      AmpAdapter.execute(adapter, run, session,
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        timeout: 5_000
      )

      events = collect_events()
      event_types = Enum.map(events, & &1.type)

      assert :error_occurred in event_types
      assert :run_failed in event_types
    end

    test "error includes permission denials when present" do
      {:ok, adapter} =
        start_test_adapter(
          scenario: :error,
          error_message: "Permission denied",
          permission_denials: ["file_write", "bash_exec"]
        )

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      AmpAdapter.execute(adapter, run, session,
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        timeout: 5_000
      )

      events = collect_events()
      error_event = Enum.find(events, &(&1.type == :error_occurred))

      assert error_event != nil
      assert error_event.data.permission_denials == ["file_write", "bash_exec"]
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

      task =
        Task.async(fn ->
          AmpAdapter.execute(adapter, run, session, timeout: 30_000)
        end)

      Process.sleep(50)

      run_id = run.id
      {:ok, ^run_id} = AmpAdapter.cancel(adapter, run.id)

      result = Task.await(task, 5_000)

      case result do
        {:error, %Error{code: :cancelled}} -> :ok
        {:ok, _} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "returns error for unknown run_id" do
      {:ok, adapter} = start_test_adapter()

      result = AmpAdapter.cancel(adapter, "non-existent-run-id")

      assert {:error, %Error{code: :run_not_found}} = result
    end
  end

  describe "event callback" do
    test "callback receives events in real-time" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()
      assert events != []
    end

    test "events also collected in result.events" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      test_pid = self()

      {:ok, result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      callback_events = collect_events()

      assert length(result.events) == length(callback_events)
    end
  end

  describe "worker failure isolation" do
    test "returns internal_error and keeps adapter alive" do
      {:ok, adapter} =
        AmpAdapter.start_link(
          cwd: "/tmp/test",
          sdk_module: FailingMockAmpSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Hello")

      assert {:error, %Error{code: :internal_error}} = AmpAdapter.execute(adapter, run, session)
      assert Process.alive?(adapter)
      assert {:ok, _caps} = AmpAdapter.capabilities(adapter)
    end
  end

  describe "event provider attribution" do
    test "all events include provider: :amp" do
      {:ok, adapter} = start_test_adapter(scenario: :with_tool_call)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end,
          timeout: 5_000
        )

      events = collect_events()

      for event <- events do
        assert event.provider == :amp,
               "Event #{event.type} missing provider :amp"
      end
    end

    test "events include session_id and run_id" do
      {:ok, adapter} = start_test_adapter(scenario: :simple_response)

      session = build_test_session()
      run = build_test_run(session_id: session.id, input: "Test")

      test_pid = self()

      {:ok, _result} =
        AmpAdapter.execute(adapter, run, session,
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
        AmpAdapter.start_link(
          cwd: "/tmp/test",
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

      assert {:ok, _result} = AmpAdapter.execute(adapter, run, session, timeout: 5_000)
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

          AmpAdapter.execute(adapter, run, session, timeout: 5_000)
        end)

      for result <- results do
        assert {:ok, _} = result
      end
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp start_test_adapter(opts \\ []) do
    scenario = Keyword.get(opts, :scenario, :simple_response)
    delay_ms = Keyword.get(opts, :delay_ms, 0)
    chunks = Keyword.get(opts, :chunks)
    content = Keyword.get(opts, :content)
    tool_name = Keyword.get(opts, :tool_name)
    tool_id = Keyword.get(opts, :tool_id)
    tool_input = Keyword.get(opts, :tool_input)
    tool_output = Keyword.get(opts, :tool_output)
    tool_is_error = Keyword.get(opts, :tool_is_error)
    error_message = Keyword.get(opts, :error_message)
    permission_denials = Keyword.get(opts, :permission_denials)

    mock_opts =
      [scenario: scenario, delay_ms: delay_ms]
      |> maybe_add(:chunks, chunks)
      |> maybe_add(:content, content)
      |> maybe_add(:tool_name, tool_name)
      |> maybe_add(:tool_id, tool_id)
      |> maybe_add(:tool_input, tool_input)
      |> maybe_add(:tool_output, tool_output)
      |> maybe_add(:tool_is_error, tool_is_error)
      |> maybe_add(:error_message, error_message)
      |> maybe_add(:permission_denials, permission_denials)

    {:ok, mock_sdk} = AmpMockSDK.start_link(mock_opts)
    cleanup_on_exit(fn -> safe_stop(mock_sdk) end)

    {:ok, adapter} =
      AmpAdapter.start_link(
        cwd: "/tmp/test",
        sdk_module: AmpMockSDK,
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

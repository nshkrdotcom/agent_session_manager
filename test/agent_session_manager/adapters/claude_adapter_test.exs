defmodule AgentSessionManager.Adapters.ClaudeAdapterTest do
  @moduledoc """
  Tests for the Claude provider adapter.

  These tests verify:
  1. Event mapping from Claude events to normalized events
  2. Capability advertisement
  3. Streaming message handling
  4. Interrupt/cancel support
  5. Error handling (rate limits, timeouts, disconnects)

  All tests use the MockSDK to simulate Claude API responses.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.Claude.MockSDK
  alias AgentSessionManager.Adapters.ClaudeAdapter
  alias AgentSessionManager.Core.{Capability, Error, NormalizedEvent, Run, Session, Transcript}
  alias AgentSessionManager.Test.ClaudeAgentSDKMock
  alias AgentSessionManager.Test.Models, as: TestModels

  defmodule FailingAgentSDK do
    @moduledoc false

    def query(_sdk_pid, _input, _opts) do
      raise "boom in query"
    end
  end

  defmodule OptionsCapturingSDK do
    @moduledoc false

    alias ClaudeAgentSDK.Message

    def query(test_pid, _input, opts) do
      send(test_pid, {:captured_sdk_options, opts})

      [
        %Message{
          type: :system,
          subtype: :init,
          data: %{session_id: "claude-session", model: TestModels.claude_model(), tools: []},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{usage: %{"input_tokens" => 1, "output_tokens" => 1}},
          raw: %{}
        }
      ]
    end
  end

  defmodule CapturingAgentSDK do
    @moduledoc false

    alias ClaudeAgentSDK.Message

    def query(test_pid, input, _opts) do
      send(test_pid, {:captured_input, input})

      [
        %Message{
          type: :system,
          subtype: :init,
          data: %{session_id: "claude-session", model: TestModels.claude_model(), tools: []},
          raw: %{}
        },
        %Message{
          type: :assistant,
          subtype: nil,
          data: %{
            message: %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "ok"}]
            }
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{usage: %{"input_tokens" => 1, "output_tokens" => 1}},
          raw: %{}
        }
      ]
    end
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    {:ok, session} = Session.new(%{agent_id: "claude-test-agent"})

    {:ok, run} =
      Run.new(%{session_id: session.id, input: %{messages: [%{role: "user", content: "Hello"}]}})

    {:ok, session: session, run: run}
  end

  # ============================================================================
  # Provider Identity Tests
  # ============================================================================

  describe "name/1" do
    test "returns 'claude' as the provider name" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert ClaudeAdapter.name(adapter) == "claude"
    end
  end

  # ============================================================================
  # Capability Advertisement Tests
  # ============================================================================

  describe "capabilities/1" do
    test "returns list of supported capabilities" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      assert is_list(capabilities)
      assert capabilities != []
      assert Enum.all?(capabilities, &match?(%Capability{}, &1))
    end

    test "advertises streaming capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      streaming_cap = Enum.find(capabilities, &(&1.name == "streaming"))
      assert streaming_cap != nil
      assert streaming_cap.type == :sampling
      assert streaming_cap.enabled == true
    end

    test "advertises tool_use capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      tool_cap = Enum.find(capabilities, &(&1.name == "tool_use"))
      assert tool_cap != nil
      assert tool_cap.type == :tool
      assert tool_cap.enabled == true
    end

    test "advertises vision capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      vision_cap = Enum.find(capabilities, &(&1.name == "vision"))
      assert vision_cap != nil
      assert vision_cap.type == :resource
      assert vision_cap.enabled == true
    end

    test "advertises system_prompts capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      prompt_cap = Enum.find(capabilities, &(&1.name == "system_prompts"))
      assert prompt_cap != nil
      assert prompt_cap.type == :prompt
      assert prompt_cap.enabled == true
    end

    test "capabilities have valid types" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      assert Enum.all?(capabilities, fn cap ->
               Capability.valid_type?(cap.type)
             end)
    end

    test "advertises interrupt support capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      interrupt_cap = Enum.find(capabilities, &(&1.name == "interrupt"))
      assert interrupt_cap != nil
      assert interrupt_cap.enabled == true
    end
  end

  # ============================================================================
  # Configuration Validation Tests
  # ============================================================================

  describe "validate_config/2" do
    test "returns :ok for valid config with api_key" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      config = %{api_key: "sk-ant-api03-xxxxx"}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)
    end

    test "accepts config without api_key (SDK handles auth)" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      config = %{model: TestModels.claude_model()}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)
    end

    test "accepts config with empty api_key (SDK handles auth)" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      config = %{api_key: ""}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)
    end

    test "accepts optional model configuration" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      config = %{api_key: "sk-xxx", model: TestModels.claude_model()}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)
    end
  end

  # ============================================================================
  # Event Mapping Tests - Successful Stream
  # ============================================================================

  describe "execute/4 - event mapping for successful stream" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "maps message_start to run_started event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      # Start execution in a task since we control event emission
      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      # Allow adapter to set up subscription
      Process.sleep(50)

      # Emit message_start event
      MockSDK.emit_next(mock)

      # Should receive run_started
      assert_receive {:event, event}, 1000
      assert event.type == :run_started
      assert event.session_id == session.id
      assert event.run_id == run.id
      assert event.provider == :claude

      # Complete remaining events
      MockSDK.complete(mock)

      Task.await(task)
    end

    test "maps content_block_delta to message_streamed events", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)

      # Emit all events
      MockSDK.complete(mock)

      # Collect all events
      events = collect_events(test_pid, 1000)

      # Should have message_streamed events for text deltas
      streamed_events = Enum.filter(events, &(&1.type == :message_streamed))
      refute Enum.empty?(streamed_events)

      # Each streamed event should have content
      Enum.each(streamed_events, fn event ->
        assert Map.has_key?(event.data, :content) or Map.has_key?(event.data, :delta)
      end)

      Task.await(task)
    end

    test "maps message_stop to run_completed event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      events = collect_events(test_pid, 1000)

      # Should have run_completed as last event type
      completed_events = Enum.filter(events, &(&1.type == :run_completed))
      assert length(completed_events) == 1

      completed = hd(completed_events)
      assert completed.session_id == session.id
      assert completed.run_id == run.id

      Task.await(task)
    end

    test "accumulates full content in message_received event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      events = collect_events(test_pid, 1000)

      # Should have message_received with full content
      received_events = Enum.filter(events, &(&1.type == :message_received))
      assert length(received_events) == 1

      received = hd(received_events)
      assert received.data.content == "Hello! How can I help you today?"

      Task.await(task)
    end

    test "includes token_usage_updated event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      events = collect_events(test_pid, 1000)

      # Should have token_usage_updated event
      usage_events = Enum.filter(events, &(&1.type == :token_usage_updated))
      refute Enum.empty?(usage_events)

      usage = hd(usage_events)
      assert Map.has_key?(usage.data, :input_tokens)
      assert Map.has_key?(usage.data, :output_tokens)

      Task.await(task)
    end

    test "returns result with output and token_usage", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      {:ok, result} = Task.await(task)

      assert is_map(result)
      assert Map.has_key?(result, :output)
      assert Map.has_key?(result, :token_usage)
      assert result.output.content == "Hello! How can I help you today?"
      assert result.token_usage.input_tokens == 25
      assert result.token_usage.output_tokens == 15
    end

    test "returns result.events with emitted events", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      {:ok, result} = Task.await(task)

      assert is_list(result.events)
      refute Enum.empty?(result.events)
      assert Enum.any?(result.events, &(&1.type == :run_started))
      assert Enum.any?(result.events, &(&1.type == :run_completed))
    end
  end

  # ============================================================================
  # Event Mapping Tests - Tool Use Response
  # ============================================================================

  describe "execute/4 - event mapping for tool use" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :tool_use_response)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "maps tool_use content block to tool_call_started event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      events = collect_events(test_pid, 1000)

      # Should have tool_call_started event
      tool_started = Enum.filter(events, &(&1.type == :tool_call_started))
      assert length(tool_started) == 1

      tool_event = hd(tool_started)
      assert tool_event.data.tool_name == "get_weather"
      assert tool_event.data.tool_call_id != nil

      Task.await(task)
    end

    test "maps tool use completion to tool_call_completed event", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      events = collect_events(test_pid, 1000)

      # Should have tool_call_completed event
      tool_completed = Enum.filter(events, &(&1.type == :tool_call_completed))
      assert length(tool_completed) == 1

      tool_event = hd(tool_completed)
      assert tool_event.data.tool_name == "get_weather"
      assert tool_event.data.tool_call_id != nil
      assert tool_event.data.tool_input == %{"location" => "San Francisco"}

      Task.await(task)
    end

    test "result indicates tool_use stop reason", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)

      {:ok, result} = Task.await(task)

      assert result.output.stop_reason == "tool_use"
      assert length(result.output.tool_calls) == 1

      [tool_call] = result.output.tool_calls
      assert tool_call.name == "get_weather"
      assert tool_call.input == %{"location" => "San Francisco"}
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "execute/4 - rate limit error" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :rate_limit_error)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "returns rate limit error", %{adapter: adapter, session: session, run: run} do
      result = ClaudeAdapter.execute(adapter, run, session)

      assert {:error, %Error{code: :provider_rate_limited}} = result
    end

    test "error includes retry-after information", %{adapter: adapter, session: session, run: run} do
      {:error, error} = ClaudeAdapter.execute(adapter, run, session)

      assert error.code == :provider_rate_limited
      assert error.provider_error != nil
      assert error.provider_error.status_code == 429
    end

    test "emits error_occurred event", %{adapter: adapter, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      error_events = Enum.filter(events, &(&1.type == :error_occurred))
      refute Enum.empty?(error_events)

      error_event = hd(error_events)
      assert error_event.data.error_code == :provider_rate_limited
    end
  end

  describe "execute/4 - network timeout" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :network_timeout)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "returns timeout error", %{adapter: adapter, session: session, run: run} do
      result = ClaudeAdapter.execute(adapter, run, session)

      assert {:error, %Error{code: :provider_timeout}} = result
    end

    test "emits run_failed event", %{adapter: adapter, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      failed_events = Enum.filter(events, &(&1.type == :run_failed))
      assert length(failed_events) == 1
    end
  end

  describe "execute/4 - partial disconnect" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :partial_disconnect)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "handles partial response followed by disconnect", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)

      # Emit partial events then force disconnect error
      # message_start
      MockSDK.emit_next(mock)
      # content_block_start
      MockSDK.emit_next(mock)
      # content_block_delta
      MockSDK.emit_next(mock)

      # Force disconnect error
      error = Error.new(:provider_error, "Connection lost")
      MockSDK.force_error(mock, error)

      result = Task.await(task)

      assert {:error, %Error{code: :provider_error}} = result
    end

    test "emits events received before disconnect", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)

      # Emit some events
      MockSDK.emit_next(mock)
      MockSDK.emit_next(mock)

      # Force error
      MockSDK.force_error(mock, Error.new(:provider_error, "Disconnected"))

      Task.await(task)

      events = collect_events(test_pid, 500)

      # Should have some events before the error
      assert length(events) >= 2

      # Should have run_started
      assert Enum.any?(events, &(&1.type == :run_started))
    end
  end

  # ============================================================================
  # Cancel/Interrupt Tests
  # ============================================================================

  describe "cancel/2" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "cancels an in-progress run", %{adapter: adapter, mock: mock, session: session, run: run} do
      # Start execution
      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session)
        end)

      Process.sleep(50)

      # Emit first event to establish stream
      MockSDK.emit_next(mock)

      # Cancel the run
      run_id = run.id
      result = ClaudeAdapter.cancel(adapter, run.id)
      assert {:ok, ^run_id} = result

      # Task should complete (with cancellation)
      result = Task.await(task, 1000)
      assert {:error, %Error{code: :cancelled}} = result
    end

    test "emits run_cancelled event", %{adapter: adapter, mock: mock, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.emit_next(mock)

      ClaudeAdapter.cancel(adapter, run.id)

      Task.await(task, 1000)

      events = collect_events(test_pid, 500)

      cancelled_events = Enum.filter(events, &(&1.type == :run_cancelled))
      assert length(cancelled_events) == 1
    end

    test "returns error when no run is in progress", %{adapter: adapter} do
      result = ClaudeAdapter.cancel(adapter, "non-existent-run-id")

      assert {:error, %Error{code: :run_not_found}} = result
    end
  end

  describe "worker failure isolation" do
    test "returns internal_error and keeps adapter alive", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: FailingAgentSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:error, %Error{code: :internal_error}} =
               ClaudeAdapter.execute(adapter, run, session)

      assert Process.alive?(adapter)
      assert {:ok, _caps} = ClaudeAdapter.capabilities(adapter)
    end
  end

  # ============================================================================
  # Event Order Tests
  # ============================================================================

  describe "event ordering" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "run_started is always first", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      refute Enum.empty?(events)
      first_event = hd(events)
      assert first_event.type == :run_started
    end

    test "run_completed is always last for successful execution", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      refute Enum.empty?(events)
      last_event = List.last(events)
      assert last_event.type == :run_completed
    end

    test "message_streamed events occur between start and completion", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      # Get indices of key events
      start_idx = Enum.find_index(events, &(&1.type == :run_started))
      complete_idx = Enum.find_index(events, &(&1.type == :run_completed))

      streamed_indices =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {event, _idx} -> event.type == :message_streamed end)
        |> Enum.map(fn {_event, idx} -> idx end)

      # All streamed events should be between start and complete
      Enum.each(streamed_indices, fn idx ->
        assert idx > start_idx
        assert idx < complete_idx
      end)
    end
  end

  # ============================================================================
  # Normalized Event Structure Tests
  # ============================================================================

  describe "normalized event structure" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "events have all required fields", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      Enum.each(events, fn event ->
        assert Map.has_key?(event, :type)
        assert Map.has_key?(event, :timestamp)
        assert Map.has_key?(event, :session_id)
        assert Map.has_key?(event, :run_id)
        assert Map.has_key?(event, :data)
      end)
    end

    test "events include provider information", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      Enum.each(events, fn event ->
        assert event.provider == :claude
      end)
    end

    test "events can be converted to NormalizedEvent structs", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      task =
        Task.async(fn ->
          ClaudeAdapter.execute(adapter, run, session, event_callback: callback)
        end)

      Process.sleep(50)
      MockSDK.complete(mock)
      Task.await(task)

      events = collect_events(test_pid, 500)

      # All events should be convertible to NormalizedEvent
      Enum.each(events, fn event ->
        result =
          NormalizedEvent.new(%{
            type: event.type,
            session_id: event.session_id,
            run_id: event.run_id,
            data: event.data,
            provider: event.provider
          })

        assert {:ok, %NormalizedEvent{}} = result
      end)
    end
  end

  # ============================================================================
  # ClaudeAgentSDK Integration Tests
  # ============================================================================

  describe "execute/4 with ClaudeAgentSDK (query/3 interface)" do
    setup context do
      {:ok, mock} = ClaudeAgentSDKMock.start_link(scenario: :simple_response)

      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: ClaudeAgentSDKMock,
          sdk_pid: mock
        )

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "maps system init message to run_started event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      run_started = Enum.find(events, &(&1.type == :run_started))
      assert run_started != nil
      assert run_started.provider == :claude
      assert run_started.session_id == session.id
      assert run_started.run_id == run.id
      assert run_started.data.session_id != nil
    end

    test "maps assistant messages to message_streamed events", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      streamed = Enum.filter(events, &(&1.type == :message_streamed))
      refute Enum.empty?(streamed)

      first_streamed = hd(streamed)
      assert first_streamed.data.content != nil
      assert first_streamed.data.delta != nil
    end

    test "maps result success to run_completed event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      completed = Enum.find(events, &(&1.type == :run_completed))
      assert completed != nil
      assert completed.data.stop_reason == "end_turn"
      assert completed.data.token_usage.input_tokens >= 0
      assert completed.data.token_usage.output_tokens >= 0
    end

    test "returns result with output content", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert result.output.content =~ "Hello"
      assert result.output.stop_reason == "end_turn"
    end

    test "includes token_usage in result", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert result.token_usage.input_tokens >= 0
      assert result.token_usage.output_tokens >= 0
    end

    test "returns result.events with emitted events", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert is_list(result.events)
      refute Enum.empty?(result.events)
      assert Enum.any?(result.events, &(&1.type == :run_started))
      assert Enum.any?(result.events, &(&1.type == :run_completed))
    end

    test "emits token_usage_updated event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      usage_event = Enum.find(events, &(&1.type == :token_usage_updated))
      assert usage_event != nil
      assert Map.has_key?(usage_event.data, :input_tokens)
      assert Map.has_key?(usage_event.data, :output_tokens)
    end

    test "emits cache token fields when usage includes cache token counts", %{
      adapter: adapter,
      mock: mock,
      session: session,
      run: run
    } do
      messages = [
        %ClaudeAgentSDK.Message{
          type: :system,
          subtype: :init,
          data: %{session_id: "cache-session", model: TestModels.claude_opus_model(), tools: []},
          raw: %{}
        },
        %ClaudeAgentSDK.Message{
          type: :assistant,
          subtype: nil,
          data: %{
            message: %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "cached response"}]
            }
          },
          raw: %{}
        },
        %ClaudeAgentSDK.Message{
          type: :result,
          subtype: :success,
          data: %{
            usage: %{
              "input_tokens" => 1000,
              "output_tokens" => 500,
              "cache_read_input_tokens" => 800,
              "cache_creation_input_tokens" => 200
            },
            stop_reason: "end_turn"
          },
          raw: %{}
        }
      ]

      :ok = ClaudeAgentSDKMock.set_messages(mock, messages)
      test_pid = self()

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session,
          event_callback: fn event -> send(test_pid, {:event, event}) end
        )

      events = collect_events(test_pid, 500)
      usage_event = Enum.find(events, &(&1.type == :token_usage_updated))
      assert usage_event != nil
      assert usage_event.data.cache_read_tokens == 800
      assert usage_event.data.cache_creation_tokens == 200
    end

    test "emits message_received with accumulated content", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      received = Enum.find(events, &(&1.type == :message_received))
      assert received != nil
      assert received.data.content =~ "Hello"
      assert received.data.role == "assistant"
    end
  end

  describe "execute/4 with ClaudeAgentSDK streaming" do
    setup context do
      {:ok, mock} =
        ClaudeAgentSDKMock.start_link(
          scenario: :streaming,
          chunks: ["Part 1", " ", "Part 2", " ", "Part 3"]
        )

      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: ClaudeAgentSDKMock,
          sdk_pid: mock
        )

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "emits multiple message_streamed events for streaming chunks", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      streamed_events = Enum.filter(events, &(&1.type == :message_streamed))
      assert length(streamed_events) >= 3
    end

    test "accumulates all chunks in final content", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert result.output.content =~ "Part 1"
      assert result.output.content =~ "Part 2"
      assert result.output.content =~ "Part 3"
    end
  end

  describe "execute/4 with ClaudeAgentSDK tool use" do
    setup context do
      {:ok, mock} =
        ClaudeAgentSDKMock.start_link(
          scenario: :with_tool_use,
          tool_name: "read_file",
          tool_id: "toolu_test_abc123",
          tool_input: %{"path" => "/test/file.txt"}
        )

      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: ClaudeAgentSDKMock,
          sdk_pid: mock
        )

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "emits tool_call_started event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      started = Enum.find(events, &(&1.type == :tool_call_started))
      assert started != nil
      assert started.data.tool_name == "read_file"
      assert started.data.tool_call_id == "toolu_test_abc123"
      refute Map.has_key?(started.data, :tool_use_id)
      refute Map.has_key?(started.data, :arguments)
    end

    test "emits tool_call_completed event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      completed = Enum.find(events, &(&1.type == :tool_call_completed))
      assert completed != nil
      assert completed.data.tool_name == "read_file"
      assert completed.data.tool_call_id == "toolu_test_abc123"
      assert completed.data.tool_input == %{"path" => "/test/file.txt"}
      refute Map.has_key?(completed.data, :tool_use_id)
      refute Map.has_key?(completed.data, :input)
    end

    test "includes tool_calls in result output", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert [tool_call | _] = result.output.tool_calls
      assert tool_call.name == "read_file"
      assert tool_call.id == "toolu_test_abc123"
      assert tool_call.input == %{"path" => "/test/file.txt"}
    end
  end

  describe "execute/4 with ClaudeAgentSDK error" do
    setup context do
      {:ok, mock} =
        ClaudeAgentSDKMock.start_link(
          scenario: :error,
          error_message: "Rate limit exceeded"
        )

      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: ClaudeAgentSDKMock,
          sdk_pid: mock
        )

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "returns error for failed execution", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      result = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert {:error, %Error{code: :provider_error}} = result
    end

    test "emits error_occurred event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      error_event = Enum.find(events, &(&1.type == :error_occurred))
      assert error_event != nil
      assert error_event.data.error_code == :provider_error
    end

    test "emits run_failed event", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      failed_event = Enum.find(events, &(&1.type == :run_failed))
      assert failed_event != nil
    end
  end

  describe "ClaudeAgentSDK event provider attribution" do
    setup context do
      {:ok, mock} = ClaudeAgentSDKMock.start_link(scenario: :with_tool_use)

      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: ClaudeAgentSDKMock,
          sdk_pid: mock
        )

      cleanup_on_exit(fn -> safe_stop(mock) end)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      Map.merge(context, %{mock: mock, adapter: adapter})
    end

    test "all events include provider: :claude", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      for event <- events do
        assert event.provider == :claude, "Event #{event.type} missing provider :claude"
      end
    end

    test "all events include correct session_id and run_id", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} =
        ClaudeAdapter.execute(adapter, run, session, event_callback: callback)

      events = collect_events(test_pid, 500)

      for event <- events do
        assert event.session_id == session.id
        assert event.run_id == run.id
      end
    end
  end

  describe "transcript continuity input" do
    test "replays transcript context in adapter input when session transcript is present", %{
      session: session,
      run: run
    } do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: CapturingAgentSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      session_with_transcript = %{
        session
        | context: %{
            transcript: %Transcript{
              session_id: session.id,
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
              last_sequence: 5,
              last_timestamp: DateTime.utc_now(),
              metadata: %{}
            }
          }
      }

      assert {:ok, _result} =
               ClaudeAdapter.execute(adapter, run, session_with_transcript, timeout: 5_000)

      assert_receive {:captured_input, input}, 1_000

      assert contains_text?(input, "Earlier assistant reply")
      assert contains_text?(input, "Hello")
    end
  end

  # ============================================================================
  # Permission Mode Configuration Tests
  # ============================================================================

  describe "permission_mode configuration" do
    test "stores permission_mode in adapter state" do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :full_auto
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.permission_mode == :full_auto
    end

    test "defaults permission_mode to nil when not provided" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.permission_mode == nil
    end

    test "full_auto maps to bypass_permissions on SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :full_auto,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == :bypass_permissions
    end

    test "dangerously_skip_permissions maps to bypass_permissions on SDK options", %{
      session: session,
      run: run
    } do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :dangerously_skip_permissions,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == :bypass_permissions
    end

    test "accept_edits maps to accept_edits on SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :accept_edits,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == :accept_edits
    end

    test "plan maps to plan on SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :plan,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == :plan
    end

    test "default permission_mode omits it from SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          permission_mode: :default,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == nil
    end

    test "nil permission_mode omits it from SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.permission_mode == nil
    end
  end

  describe "max_turns configuration" do
    test "defaults max_turns to nil (unlimited) in adapter state" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.max_turns == nil
    end

    test "stores explicit max_turns in adapter state" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key", max_turns: 5)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.max_turns == 5
    end

    test "default max_turns passes nil to SDK options (unlimited)", %{
      session: session,
      run: run
    } do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.max_turns == nil
    end

    test "explicit max_turns is passed to SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          max_turns: 10,
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.max_turns == 10
    end
  end

  describe "sdk_opts passthrough" do
    test "defaults sdk_opts to empty list in adapter state" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      state = :sys.get_state(adapter)
      assert state.sdk_opts == []
    end

    test "sdk_opts fields are merged into SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_opts: [verbose: true, max_budget_usd: 1.0],
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.verbose == true
      assert opts.max_budget_usd == 1.0
    end

    test "normalized options take precedence over sdk_opts", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          max_turns: 5,
          sdk_opts: [max_turns: 99],
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      # Normalized max_turns should win over sdk_opts
      assert opts.max_turns == 5
    end

    test "system_prompt is passed through to SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          system_prompt: "You are a helpful assistant.",
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.system_prompt == "You are a helpful assistant."
    end

    test "cwd is passed through to SDK options", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          cwd: "/tmp/my-project",
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.cwd == "/tmp/my-project"
    end

    test "cwd defaults to nil when not provided", %{session: session, run: run} do
      {:ok, adapter} =
        ClaudeAdapter.start_link(
          api_key: "test-key",
          sdk_module: OptionsCapturingSDK,
          sdk_pid: self()
        )

      cleanup_on_exit(fn -> safe_stop(adapter) end)

      assert {:ok, _result} = ClaudeAdapter.execute(adapter, run, session, timeout: 5_000)

      assert_receive {:captured_sdk_options, opts}, 1_000
      assert opts.cwd == nil
    end
  end

  # ============================================================================
  # Streaming multi-turn tool use
  # ============================================================================

  describe "streaming multi-turn tool use" do
    test "continues stream past message_stop with tool_use stop_reason", %{
      session: session,
      run: run
    } do
      test_pid = self()

      ctx = %{
        run: run,
        session: session,
        prepared_input: "test prompt",
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        adapter_pid: self(),
        accumulated_content: "",
        content_blocks: %{},
        tool_calls: [],
        token_usage: %{input_tokens: 0, output_tokens: 0},
        session_id: "test-session"
      }

      events = [
        # Turn 1: assistant requests tool use
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 10}}}
        },
        %{type: :text_delta, text: "Let me read that file."},
        %{
          type: :tool_use_start,
          id: "toolu_123",
          name: "Bash",
          input: %{"command" => "cat /test.txt"}
        },
        %{
          type: :message_delta,
          stop_reason: "tool_use",
          raw_event: %{"usage" => %{"output_tokens" => 20}}
        },
        %{type: :message_stop},
        # Turn 2: assistant responds after tool result
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 50}}}
        },
        %{type: :text_delta, text: "Here are the file contents."},
        %{
          type: :message_delta,
          stop_reason: "end_turn",
          raw_event: %{"usage" => %{"output_tokens" => 15}}
        },
        %{type: :message_stop}
      ]

      {:ok, result} = ClaudeAdapter.process_streaming_events_for_test(events, ctx)

      all_events = collect_events(test_pid, 500)

      # Should have two message_received events (one per turn)
      msg_events = Enum.filter(all_events, &(&1.type == :message_received))
      assert length(msg_events) == 2

      # First message should have turn 1 content
      assert hd(msg_events).data.content =~ "Let me read that file."

      # Should have tool_call_started event
      tool_events = Enum.filter(all_events, &(&1.type == :tool_call_started))
      assert length(tool_events) == 1
      assert hd(tool_events).data.tool_name == "Bash"

      # Should have exactly one run_completed (at the end)
      completed = Enum.filter(all_events, &(&1.type == :run_completed))
      assert length(completed) == 1
      assert hd(completed).data.stop_reason == "end_turn"

      # Final result content should be the last turn's content
      assert result.output.content =~ "Here are the file contents"
    end

    test "halts on message_stop without tool_use stop_reason", %{
      session: session,
      run: run
    } do
      test_pid = self()

      ctx = %{
        run: run,
        session: session,
        prepared_input: "test prompt",
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        adapter_pid: self(),
        accumulated_content: "",
        content_blocks: %{},
        tool_calls: [],
        token_usage: %{input_tokens: 0, output_tokens: 0},
        session_id: "test-session"
      }

      events = [
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 10}}}
        },
        %{type: :text_delta, text: "Hello, I can help!"},
        %{
          type: :message_delta,
          stop_reason: "end_turn",
          raw_event: %{"usage" => %{"output_tokens" => 5}}
        },
        %{type: :message_stop}
      ]

      {:ok, result} = ClaudeAdapter.process_streaming_events_for_test(events, ctx)

      all_events = collect_events(test_pid, 500)

      # Should have exactly one message_received
      msg_events = Enum.filter(all_events, &(&1.type == :message_received))
      assert length(msg_events) == 1

      # Should have exactly one run_completed
      completed = Enum.filter(all_events, &(&1.type == :run_completed))
      assert length(completed) == 1
      assert hd(completed).data.stop_reason == "end_turn"

      assert result.output.content == "Hello, I can help!"
    end

    test "does not emit run_completed on intermediate tool_use message_stop", %{
      session: session,
      run: run
    } do
      test_pid = self()

      ctx = %{
        run: run,
        session: session,
        prepared_input: "test prompt",
        event_callback: fn event -> send(test_pid, {:event, event}) end,
        adapter_pid: self(),
        accumulated_content: "",
        content_blocks: %{},
        tool_calls: [],
        token_usage: %{input_tokens: 0, output_tokens: 0},
        session_id: "test-session"
      }

      events = [
        # Turn 1: tool use
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 10}}}
        },
        %{type: :text_delta, text: "Checking..."},
        %{
          type: :message_delta,
          stop_reason: "tool_use",
          raw_event: %{"usage" => %{"output_tokens" => 8}}
        },
        %{type: :message_stop},
        # Turn 2: tool use again
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 30}}}
        },
        %{type: :text_delta, text: "Writing..."},
        %{
          type: :message_delta,
          stop_reason: "tool_use",
          raw_event: %{"usage" => %{"output_tokens" => 12}}
        },
        %{type: :message_stop},
        # Turn 3: final response
        %{
          type: :message_start,
          model: "claude-haiku-4-5",
          usage: %{},
          raw_event: %{"message" => %{"usage" => %{"input_tokens" => 60}}}
        },
        %{type: :text_delta, text: "All done!"},
        %{
          type: :message_delta,
          stop_reason: "end_turn",
          raw_event: %{"usage" => %{"output_tokens" => 5}}
        },
        %{type: :message_stop}
      ]

      {:ok, result} = ClaudeAdapter.process_streaming_events_for_test(events, ctx)

      all_events = collect_events(test_pid, 500)

      # Three message_received events (one per turn)
      msg_events = Enum.filter(all_events, &(&1.type == :message_received))
      assert length(msg_events) == 3

      # Only ONE run_completed at the very end
      completed = Enum.filter(all_events, &(&1.type == :run_completed))
      assert length(completed) == 1
      assert hd(completed).data.stop_reason == "end_turn"

      # Three run_started events (one per message_start)
      started = Enum.filter(all_events, &(&1.type == :run_started))
      assert length(started) == 3

      assert result.output.content == "All done!"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Collect events with smart timeout:
  # - Initial timeout to wait for first event
  # - Short drain timeout after receiving events to quickly collect remaining
  # - Stop immediately when we see a terminal event (run_completed, run_failed)
  @terminal_events [:run_completed, :run_failed, :run_cancelled]
  @drain_timeout 50

  defp collect_events(_pid, timeout) do
    collect_events_loop(timeout, [])
  end

  defp collect_events_loop(timeout, acc) do
    receive do
      {:event, event} ->
        new_acc = acc ++ [event]

        # If this is a terminal event, we're done
        if event.type in @terminal_events do
          new_acc
        else
          # Use short drain timeout after receiving an event
          collect_events_loop(@drain_timeout, new_acc)
        end
    after
      timeout ->
        acc
    end
  end

  defp contains_text?(input, text) when is_binary(input) do
    String.contains?(input, text)
  end

  defp contains_text?(%{messages: messages}, text) when is_list(messages) do
    Enum.any?(messages, fn message ->
      content = Map.get(message, :content) || Map.get(message, "content")
      is_binary(content) and String.contains?(content, text)
    end)
  end

  defp contains_text?(other, text) do
    other
    |> inspect()
    |> String.contains?(text)
  end
end

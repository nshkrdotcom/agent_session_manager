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

  use ExUnit.Case, async: true

  alias AgentSessionManager.Adapters.Claude.MockSDK
  alias AgentSessionManager.Adapters.ClaudeAdapter
  alias AgentSessionManager.Core.{Capability, Error, NormalizedEvent, Run, Session}

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

      assert ClaudeAdapter.name(adapter) == "claude"

      ClaudeAdapter.stop(adapter)
    end
  end

  # ============================================================================
  # Capability Advertisement Tests
  # ============================================================================

  describe "capabilities/1" do
    test "returns list of supported capabilities" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      assert is_list(capabilities)
      assert capabilities != []
      assert Enum.all?(capabilities, &match?(%Capability{}, &1))

      ClaudeAdapter.stop(adapter)
    end

    test "advertises streaming capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      streaming_cap = Enum.find(capabilities, &(&1.name == "streaming"))
      assert streaming_cap != nil
      assert streaming_cap.type == :sampling
      assert streaming_cap.enabled == true

      ClaudeAdapter.stop(adapter)
    end

    test "advertises tool_use capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      tool_cap = Enum.find(capabilities, &(&1.name == "tool_use"))
      assert tool_cap != nil
      assert tool_cap.type == :tool
      assert tool_cap.enabled == true

      ClaudeAdapter.stop(adapter)
    end

    test "advertises vision capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      vision_cap = Enum.find(capabilities, &(&1.name == "vision"))
      assert vision_cap != nil
      assert vision_cap.type == :resource
      assert vision_cap.enabled == true

      ClaudeAdapter.stop(adapter)
    end

    test "advertises system_prompts capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      prompt_cap = Enum.find(capabilities, &(&1.name == "system_prompts"))
      assert prompt_cap != nil
      assert prompt_cap.type == :prompt
      assert prompt_cap.enabled == true

      ClaudeAdapter.stop(adapter)
    end

    test "capabilities have valid types" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      assert Enum.all?(capabilities, fn cap ->
               Capability.valid_type?(cap.type)
             end)

      ClaudeAdapter.stop(adapter)
    end

    test "advertises interrupt support capability" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

      interrupt_cap = Enum.find(capabilities, &(&1.name == "interrupt"))
      assert interrupt_cap != nil
      assert interrupt_cap.enabled == true

      ClaudeAdapter.stop(adapter)
    end
  end

  # ============================================================================
  # Configuration Validation Tests
  # ============================================================================

  describe "validate_config/2" do
    test "returns :ok for valid config with api_key" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      config = %{api_key: "sk-ant-api03-xxxxx"}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)

      ClaudeAdapter.stop(adapter)
    end

    test "returns error when api_key is missing" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      config = %{model: "claude-sonnet-4-20250514"}

      assert {:error, %Error{code: :validation_error}} =
               ClaudeAdapter.validate_config(adapter, config)

      ClaudeAdapter.stop(adapter)
    end

    test "returns error when api_key is empty" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      config = %{api_key: ""}

      assert {:error, %Error{code: :validation_error}} =
               ClaudeAdapter.validate_config(adapter, config)

      ClaudeAdapter.stop(adapter)
    end

    test "accepts optional model configuration" do
      {:ok, adapter} = ClaudeAdapter.start_link(api_key: "test-key")

      config = %{api_key: "sk-xxx", model: "claude-sonnet-4-20250514"}
      assert :ok = ClaudeAdapter.validate_config(adapter, config)

      ClaudeAdapter.stop(adapter)
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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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
  end

  # ============================================================================
  # Event Mapping Tests - Tool Use Response
  # ============================================================================

  describe "execute/4 - event mapping for tool use" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :tool_use_response)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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
      assert tool_event.data.tool_use_id != nil

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
      assert tool_event.data.input == %{"location" => "San Francisco"}

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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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
      result = ClaudeAdapter.cancel(adapter, run.id)
      assert {:ok, ^run} = result

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

  # ============================================================================
  # Event Order Tests
  # ============================================================================

  describe "event ordering" do
    setup context do
      {:ok, mock} = MockSDK.start_link(scenario: :successful_stream)

      {:ok, adapter} =
        ClaudeAdapter.start_link(api_key: "test-key", sdk_module: MockSDK, sdk_pid: mock)

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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

      on_exit(fn ->
        if Process.alive?(mock), do: MockSDK.stop(mock)
        if Process.alive?(adapter), do: ClaudeAdapter.stop(adapter)
      end)

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
  # Helpers
  # ============================================================================

  defp collect_events(pid, timeout) do
    collect_events(pid, timeout, [])
  end

  defp collect_events(pid, timeout, acc) do
    receive do
      {:event, event} ->
        collect_events(pid, timeout, acc ++ [event])
    after
      timeout ->
        acc
    end
  end
end

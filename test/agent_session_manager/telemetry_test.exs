defmodule AgentSessionManager.TelemetryTest do
  @moduledoc """
  Tests for telemetry event emission.

  Following TDD workflow: these tests specify expected behavior before implementation.
  """

  # NOTE: async: false because these tests manipulate global telemetry_enabled state
  # via Application.put_env, which causes race conditions with parallel execution
  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Core.{Run, Session}
  alias AgentSessionManager.Telemetry

  # ============================================================================
  # Test Setup - Ensure clean state for each test
  # ============================================================================

  setup do
    # Reset telemetry to enabled state at start of each test
    Telemetry.set_enabled(true)

    # Clear any stale messages in the mailbox from other tests
    flush_mailbox()

    on_exit(fn ->
      # Ensure telemetry is re-enabled after test
      Telemetry.set_enabled(true)
    end)

    :ok
  end

  # ============================================================================
  # Handler Module - Using module function avoids telemetry warnings
  # ============================================================================

  defmodule TestHandler do
    @moduledoc false

    def handle_event(event, measurements, metadata, %{pid: pid, ref: ref}) do
      send(pid, {:telemetry_event, ref, event, measurements, metadata})
    end
  end

  # ============================================================================
  # Test Helpers
  # ============================================================================

  # Flush all messages from the process mailbox
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp attach_test_handler(event_name) do
    ref = make_ref()
    handler_id = "test-handler-#{:erlang.unique_integer()}"

    :telemetry.attach(
      handler_id,
      event_name,
      &TestHandler.handle_event/4,
      %{pid: self(), ref: ref}
    )

    # Register cleanup to ensure handler is always detached
    on_exit(fn ->
      try do
        :telemetry.detach(handler_id)
      rescue
        _ -> :ok
      end
    end)

    {handler_id, ref}
  end

  # Wait for a telemetry event matching the given ref and session_id
  # This filters out events from other tests
  defp receive_event(ref, session_id, timeout \\ 1000) do
    receive do
      {:telemetry_event, ^ref, event, measurements, %{session_id: ^session_id} = metadata} ->
        {:ok, event, measurements, metadata}

      {:telemetry_event, ^ref, _event, _measurements, _metadata} ->
        # Event from our handler but different session - keep waiting
        receive_event(ref, session_id, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  # Assert no events matching our ref arrive within timeout
  # Events from other tests (different ref) are ignored
  defp refute_event(ref, timeout \\ 100) do
    receive do
      {:telemetry_event, ^ref, event, _measurements, metadata} ->
        flunk(
          "Unexpectedly received telemetry event: #{inspect(event)} with metadata: #{inspect(metadata)}"
        )
    after
      timeout -> :ok
    end
  end

  defp create_test_session do
    {:ok, session} = Session.new(%{agent_id: "test-agent"})
    session
  end

  defp create_test_run(session) do
    {:ok, run} = Run.new(%{session_id: session.id})
    run
  end

  # ============================================================================
  # Configuration Tests
  # ============================================================================

  describe "Telemetry.enabled?/0" do
    test "returns true by default" do
      # Clear any existing config
      Application.delete_env(:agent_session_manager, :telemetry_enabled)
      assert Telemetry.enabled?() == true
    end

    test "returns false when telemetry is disabled via config" do
      original = Application.get_env(:agent_session_manager, :telemetry_enabled)
      Application.put_env(:agent_session_manager, :telemetry_enabled, false)

      assert Telemetry.enabled?() == false

      # Restore original
      if original == nil do
        Application.delete_env(:agent_session_manager, :telemetry_enabled)
      else
        Application.put_env(:agent_session_manager, :telemetry_enabled, original)
      end
    end

    test "returns true when telemetry is explicitly enabled via config" do
      original = Application.get_env(:agent_session_manager, :telemetry_enabled)
      Application.put_env(:agent_session_manager, :telemetry_enabled, true)

      assert Telemetry.enabled?() == true

      # Restore original
      if original == nil do
        Application.delete_env(:agent_session_manager, :telemetry_enabled)
      else
        Application.put_env(:agent_session_manager, :telemetry_enabled, original)
      end
    end
  end

  describe "Telemetry.set_enabled/1" do
    test "enables telemetry" do
      Telemetry.set_enabled(true)
      assert Telemetry.enabled?() == true
    end

    test "disables telemetry" do
      Telemetry.set_enabled(false)
      assert Telemetry.enabled?() == false

      # Re-enable for other tests
      Telemetry.set_enabled(true)
    end
  end

  # ============================================================================
  # run_start Event Tests
  # ============================================================================

  describe "Telemetry.emit_run_start/2" do
    test "emits [:agent_session_manager, :run, :start] event" do
      session = create_test_session()
      run = create_test_run(session)

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :start])

      Telemetry.emit_run_start(run, session)

      assert {:ok, event, measurements, metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :run, :start]
      assert is_map(measurements)
      assert is_map(metadata)
    end

    test "includes run_id and session_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :start])

      Telemetry.emit_run_start(run, session)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.run_id == run.id
      assert metadata.session_id == session.id
    end

    test "includes agent_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :start])

      Telemetry.emit_run_start(run, session)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.agent_id == session.agent_id
    end

    test "includes system_time measurement" do
      session = create_test_session()
      run = create_test_run(session)

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :start])

      Telemetry.emit_run_start(run, session)

      assert {:ok, _event, measurements, _metadata} = receive_event(ref, session.id)
      assert is_integer(measurements.system_time)
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)

      # Disable telemetry FIRST, then attach handler
      Telemetry.set_enabled(false)
      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :start])

      # Now emit - should NOT produce any event because telemetry is disabled
      Telemetry.emit_run_start(run, session)

      # Only check for events from OUR handler (matching ref)
      refute_event(ref)

      Telemetry.set_enabled(true)
    end
  end

  # ============================================================================
  # run_end Event Tests
  # ============================================================================

  describe "Telemetry.emit_run_end/3" do
    test "emits [:agent_session_manager, :run, :stop] event" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{content: "Hello"}, token_usage: %{input: 10, output: 5}}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      Telemetry.emit_run_end(run, session, result)

      assert {:ok, event, _measurements, _metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :run, :stop]
    end

    test "includes duration measurement" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{content: "Hello"}, token_usage: %{}}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      Telemetry.emit_run_end(run, session, result)

      assert {:ok, _event, measurements, _metadata} = receive_event(ref, session.id)
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end

    test "includes token usage measurements when provided" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{}, token_usage: %{input_tokens: 100, output_tokens: 50}}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      Telemetry.emit_run_end(run, session, result)

      assert {:ok, _event, measurements, _metadata} = receive_event(ref, session.id)
      assert measurements.input_tokens == 100
      assert measurements.output_tokens == 50
    end

    test "includes run status in metadata" do
      session = create_test_session()
      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, completed_run} = Run.set_output(run, %{content: "Done"})
      result = %{output: %{}, token_usage: %{}}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      Telemetry.emit_run_end(completed_run, session, result)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.status == :completed
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{}, token_usage: %{}}

      Telemetry.set_enabled(false)
      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      Telemetry.emit_run_end(run, session, result)

      refute_event(ref)

      Telemetry.set_enabled(true)
    end
  end

  # ============================================================================
  # error Event Tests
  # ============================================================================

  describe "Telemetry.emit_error/3" do
    test "emits [:agent_session_manager, :run, :exception] event" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :provider_error, message: "API failed"}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :exception])

      Telemetry.emit_error(run, session, error)

      assert {:ok, event, _measurements, _metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :run, :exception]
    end

    test "includes error code in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :rate_limit, message: "Too many requests"}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :exception])

      Telemetry.emit_error(run, session, error)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.error_code == :rate_limit
    end

    test "includes error message in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :timeout, message: "Request timed out"}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :exception])

      Telemetry.emit_error(run, session, error)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.error_message == "Request timed out"
    end

    test "includes run_id and session_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :unknown, message: "Unknown error"}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :exception])

      Telemetry.emit_error(run, session, error)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.run_id == run.id
      assert metadata.session_id == session.id
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :error, message: "Error"}

      Telemetry.set_enabled(false)
      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :run, :exception])

      Telemetry.emit_error(run, session, error)

      refute_event(ref)

      Telemetry.set_enabled(true)
    end
  end

  # ============================================================================
  # Usage Metrics Tests
  # ============================================================================

  describe "Telemetry.emit_usage_metrics/2" do
    test "emits [:agent_session_manager, :usage, :report] event" do
      session = create_test_session()

      metrics = %{
        input_tokens: 500,
        output_tokens: 200,
        total_tokens: 700,
        cost_usd: 0.0035
      }

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :usage, :report])

      Telemetry.emit_usage_metrics(session, metrics)

      assert {:ok, event, _measurements, _metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :usage, :report]
    end

    test "includes all usage metrics as measurements" do
      session = create_test_session()

      metrics = %{
        input_tokens: 500,
        output_tokens: 200,
        total_tokens: 700
      }

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :usage, :report])

      Telemetry.emit_usage_metrics(session, metrics)

      assert {:ok, _event, measurements, _metadata} = receive_event(ref, session.id)
      assert measurements.input_tokens == 500
      assert measurements.output_tokens == 200
      assert measurements.total_tokens == 700
    end

    test "includes session_id and agent_id in metadata" do
      session = create_test_session()
      metrics = %{total_tokens: 100}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :usage, :report])

      Telemetry.emit_usage_metrics(session, metrics)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.session_id == session.id
      assert metadata.agent_id == session.agent_id
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      metrics = %{total_tokens: 100}

      Telemetry.set_enabled(false)
      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :usage, :report])

      Telemetry.emit_usage_metrics(session, metrics)

      refute_event(ref)

      Telemetry.set_enabled(true)
    end
  end

  # ============================================================================
  # Span Helper Tests
  # ============================================================================

  describe "Telemetry.span/3" do
    test "emits start and stop events for a span" do
      session = create_test_session()
      run = create_test_run(session)

      {_start_handler, start_ref} = attach_test_handler([:agent_session_manager, :run, :start])
      {_stop_handler, stop_ref} = attach_test_handler([:agent_session_manager, :run, :stop])

      result =
        Telemetry.span(
          run,
          session,
          fn ->
            Process.sleep(10)
            {:ok, %{output: %{content: "Done"}, token_usage: %{}}}
          end
        )

      assert {:ok, _} = result

      assert {:ok, [:agent_session_manager, :run, :start], _, _} =
               receive_event(start_ref, session.id)

      assert {:ok, [:agent_session_manager, :run, :stop], measurements, _} =
               receive_event(stop_ref, session.id)

      # At least 10ms in nanoseconds
      assert measurements.duration >= 10_000_000
    end

    test "emits exception event on error" do
      session = create_test_session()
      run = create_test_run(session)

      {_start_handler, start_ref} = attach_test_handler([:agent_session_manager, :run, :start])

      {_exception_handler, exception_ref} =
        attach_test_handler([:agent_session_manager, :run, :exception])

      result =
        Telemetry.span(
          run,
          session,
          fn ->
            {:error, %{code: :provider_error, message: "API failed"}}
          end
        )

      assert {:error, _} = result

      assert {:ok, [:agent_session_manager, :run, :start], _, _} =
               receive_event(start_ref, session.id)

      assert {:ok, [:agent_session_manager, :run, :exception], _, metadata} =
               receive_event(exception_ref, session.id)

      assert metadata.error_code == :provider_error
    end
  end

  # ============================================================================
  # Adapter Event Tests
  # ============================================================================

  describe "Telemetry.emit_adapter_event/4" do
    test "emits adapter event with provider namespace" do
      session = create_test_session()
      run = create_test_run(session)
      event_data = %{type: :message_streamed, data: %{content: "Hello"}, provider: :claude}

      {_handler_id, ref} =
        attach_test_handler([:agent_session_manager, :adapter, :message_streamed])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, event, _measurements, _metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :adapter, :message_streamed]
    end

    test "includes provider in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      event_data = %{type: :run_started, data: %{model: "claude-sonnet"}, provider: :claude}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :adapter, :run_started])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.provider == :claude
    end

    test "includes run_id and session_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      event_data = %{type: :run_completed, data: %{}, provider: :codex}

      {_handler_id, ref} = attach_test_handler([:agent_session_manager, :adapter, :run_completed])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, _event, _measurements, metadata} = receive_event(ref, session.id)
      assert metadata.run_id == run.id
      assert metadata.session_id == session.id
    end

    test "includes event data in measurements" do
      session = create_test_session()
      run = create_test_run(session)

      event_data = %{
        type: :token_usage_updated,
        data: %{input_tokens: 100, output_tokens: 50},
        provider: :claude
      }

      {_handler_id, ref} =
        attach_test_handler([:agent_session_manager, :adapter, :token_usage_updated])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, _event, measurements, _metadata} = receive_event(ref, session.id)
      assert measurements.input_tokens == 100
      assert measurements.output_tokens == 50
    end

    test "emits tool_call_started event" do
      session = create_test_session()
      run = create_test_run(session)

      event_data = %{
        type: :tool_call_started,
        data: %{tool_name: "read_file", tool_use_id: "call-123"},
        provider: :claude
      }

      {_handler_id, ref} =
        attach_test_handler([:agent_session_manager, :adapter, :tool_call_started])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, event, _measurements, metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :adapter, :tool_call_started]
      assert metadata.tool_name == "read_file"
    end

    test "emits tool_call_completed event" do
      session = create_test_session()
      run = create_test_run(session)

      event_data = %{
        type: :tool_call_completed,
        data: %{tool_name: "write_file", tool_use_id: "call-456"},
        provider: :codex
      }

      {_handler_id, ref} =
        attach_test_handler([:agent_session_manager, :adapter, :tool_call_completed])

      Telemetry.emit_adapter_event(run, session, event_data)

      assert {:ok, event, _measurements, metadata} = receive_event(ref, session.id)
      assert event == [:agent_session_manager, :adapter, :tool_call_completed]
      assert metadata.tool_name == "write_file"
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)
      event_data = %{type: :message_streamed, data: %{}, provider: :claude}

      Telemetry.set_enabled(false)

      {_handler_id, ref} =
        attach_test_handler([:agent_session_manager, :adapter, :message_streamed])

      Telemetry.emit_adapter_event(run, session, event_data)

      refute_event(ref)

      Telemetry.set_enabled(true)
    end
  end
end

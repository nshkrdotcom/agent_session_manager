defmodule AgentSessionManager.TelemetryTest do
  @moduledoc """
  Tests for telemetry event emission.

  Following TDD workflow: these tests specify expected behavior before implementation.
  """

  # NOTE: async: false because these tests manipulate global telemetry_enabled state
  # via Application.put_env, which causes race conditions with parallel execution
  use ExUnit.Case, async: false

  alias AgentSessionManager.Core.{Run, Session}
  alias AgentSessionManager.Telemetry

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp attach_test_handler(event_name, test_pid) do
    handler_id = "test-handler-#{:erlang.unique_integer()}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp detach_handler(handler_id) do
    :telemetry.detach(handler_id)
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

      handler_id = attach_test_handler([:agent_session_manager, :run, :start], self())

      Telemetry.emit_run_start(run, session)

      assert_receive {:telemetry_event, event, measurements, metadata}, 1000
      assert event == [:agent_session_manager, :run, :start]
      assert is_map(measurements)
      assert is_map(metadata)

      detach_handler(handler_id)
    end

    test "includes run_id and session_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)

      handler_id = attach_test_handler([:agent_session_manager, :run, :start], self())

      Telemetry.emit_run_start(run, session)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.run_id == run.id
      assert metadata.session_id == session.id

      detach_handler(handler_id)
    end

    test "includes agent_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)

      handler_id = attach_test_handler([:agent_session_manager, :run, :start], self())

      Telemetry.emit_run_start(run, session)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.agent_id == session.agent_id

      detach_handler(handler_id)
    end

    test "includes system_time measurement" do
      session = create_test_session()
      run = create_test_run(session)

      handler_id = attach_test_handler([:agent_session_manager, :run, :start], self())

      Telemetry.emit_run_start(run, session)

      assert_receive {:telemetry_event, _event, measurements, _metadata}, 1000
      assert is_integer(measurements.system_time)

      detach_handler(handler_id)
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)

      Telemetry.set_enabled(false)
      handler_id = attach_test_handler([:agent_session_manager, :run, :start], self())

      Telemetry.emit_run_start(run, session)

      refute_receive {:telemetry_event, _, _, _}, 100

      Telemetry.set_enabled(true)
      detach_handler(handler_id)
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

      handler_id = attach_test_handler([:agent_session_manager, :run, :stop], self())

      Telemetry.emit_run_end(run, session, result)

      assert_receive {:telemetry_event, event, _measurements, _metadata}, 1000
      assert event == [:agent_session_manager, :run, :stop]

      detach_handler(handler_id)
    end

    test "includes duration measurement" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{content: "Hello"}, token_usage: %{}}

      handler_id = attach_test_handler([:agent_session_manager, :run, :stop], self())

      Telemetry.emit_run_end(run, session, result)

      assert_receive {:telemetry_event, _event, measurements, _metadata}, 1000
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0

      detach_handler(handler_id)
    end

    test "includes token usage measurements when provided" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{}, token_usage: %{input_tokens: 100, output_tokens: 50}}

      handler_id = attach_test_handler([:agent_session_manager, :run, :stop], self())

      Telemetry.emit_run_end(run, session, result)

      assert_receive {:telemetry_event, _event, measurements, _metadata}, 1000
      assert measurements.input_tokens == 100
      assert measurements.output_tokens == 50

      detach_handler(handler_id)
    end

    test "includes run status in metadata" do
      session = create_test_session()
      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, completed_run} = Run.set_output(run, %{content: "Done"})
      result = %{output: %{}, token_usage: %{}}

      handler_id = attach_test_handler([:agent_session_manager, :run, :stop], self())

      Telemetry.emit_run_end(completed_run, session, result)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.status == :completed

      detach_handler(handler_id)
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)
      result = %{output: %{}, token_usage: %{}}

      Telemetry.set_enabled(false)
      handler_id = attach_test_handler([:agent_session_manager, :run, :stop], self())

      Telemetry.emit_run_end(run, session, result)

      refute_receive {:telemetry_event, _, _, _}, 100

      Telemetry.set_enabled(true)
      detach_handler(handler_id)
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

      handler_id = attach_test_handler([:agent_session_manager, :run, :exception], self())

      Telemetry.emit_error(run, session, error)

      assert_receive {:telemetry_event, event, _measurements, _metadata}, 1000
      assert event == [:agent_session_manager, :run, :exception]

      detach_handler(handler_id)
    end

    test "includes error code in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :rate_limit, message: "Too many requests"}

      handler_id = attach_test_handler([:agent_session_manager, :run, :exception], self())

      Telemetry.emit_error(run, session, error)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.error_code == :rate_limit

      detach_handler(handler_id)
    end

    test "includes error message in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :timeout, message: "Request timed out"}

      handler_id = attach_test_handler([:agent_session_manager, :run, :exception], self())

      Telemetry.emit_error(run, session, error)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.error_message == "Request timed out"

      detach_handler(handler_id)
    end

    test "includes run_id and session_id in metadata" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :unknown, message: "Unknown error"}

      handler_id = attach_test_handler([:agent_session_manager, :run, :exception], self())

      Telemetry.emit_error(run, session, error)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.run_id == run.id
      assert metadata.session_id == session.id

      detach_handler(handler_id)
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      run = create_test_run(session)
      error = %{code: :error, message: "Error"}

      Telemetry.set_enabled(false)
      handler_id = attach_test_handler([:agent_session_manager, :run, :exception], self())

      Telemetry.emit_error(run, session, error)

      refute_receive {:telemetry_event, _, _, _}, 100

      Telemetry.set_enabled(true)
      detach_handler(handler_id)
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

      handler_id = attach_test_handler([:agent_session_manager, :usage, :report], self())

      Telemetry.emit_usage_metrics(session, metrics)

      assert_receive {:telemetry_event, event, _measurements, _metadata}, 1000
      assert event == [:agent_session_manager, :usage, :report]

      detach_handler(handler_id)
    end

    test "includes all usage metrics as measurements" do
      session = create_test_session()

      metrics = %{
        input_tokens: 500,
        output_tokens: 200,
        total_tokens: 700
      }

      handler_id = attach_test_handler([:agent_session_manager, :usage, :report], self())

      Telemetry.emit_usage_metrics(session, metrics)

      assert_receive {:telemetry_event, _event, measurements, _metadata}, 1000
      assert measurements.input_tokens == 500
      assert measurements.output_tokens == 200
      assert measurements.total_tokens == 700

      detach_handler(handler_id)
    end

    test "includes session_id and agent_id in metadata" do
      session = create_test_session()
      metrics = %{total_tokens: 100}

      handler_id = attach_test_handler([:agent_session_manager, :usage, :report], self())

      Telemetry.emit_usage_metrics(session, metrics)

      assert_receive {:telemetry_event, _event, _measurements, metadata}, 1000
      assert metadata.session_id == session.id
      assert metadata.agent_id == session.agent_id

      detach_handler(handler_id)
    end

    test "does not emit event when telemetry is disabled" do
      session = create_test_session()
      metrics = %{total_tokens: 100}

      Telemetry.set_enabled(false)
      handler_id = attach_test_handler([:agent_session_manager, :usage, :report], self())

      Telemetry.emit_usage_metrics(session, metrics)

      refute_receive {:telemetry_event, _, _, _}, 100

      Telemetry.set_enabled(true)
      detach_handler(handler_id)
    end
  end

  # ============================================================================
  # Span Helper Tests
  # ============================================================================

  describe "Telemetry.span/3" do
    test "emits start and stop events for a span" do
      session = create_test_session()
      run = create_test_run(session)

      start_handler = attach_test_handler([:agent_session_manager, :run, :start], self())
      stop_handler = attach_test_handler([:agent_session_manager, :run, :stop], self())

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

      assert_receive {:telemetry_event, [:agent_session_manager, :run, :start], _, _}, 1000

      assert_receive {:telemetry_event, [:agent_session_manager, :run, :stop], measurements, _},
                     1000

      # At least 10ms in nanoseconds
      assert measurements.duration >= 10_000_000

      detach_handler(start_handler)
      detach_handler(stop_handler)
    end

    test "emits exception event on error" do
      session = create_test_session()
      run = create_test_run(session)

      start_handler = attach_test_handler([:agent_session_manager, :run, :start], self())
      exception_handler = attach_test_handler([:agent_session_manager, :run, :exception], self())

      result =
        Telemetry.span(
          run,
          session,
          fn ->
            {:error, %{code: :provider_error, message: "API failed"}}
          end
        )

      assert {:error, _} = result

      assert_receive {:telemetry_event, [:agent_session_manager, :run, :start], _, _}, 1000

      assert_receive {:telemetry_event, [:agent_session_manager, :run, :exception], _, metadata},
                     1000

      assert metadata.error_code == :provider_error

      detach_handler(start_handler)
      detach_handler(exception_handler)
    end
  end
end

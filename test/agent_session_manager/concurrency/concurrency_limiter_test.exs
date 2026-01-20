defmodule AgentSessionManager.Concurrency.ConcurrencyLimiterTest do
  @moduledoc """
  Tests for the ConcurrencyLimiter module.

  These tests follow TDD methodology - tests are written first to specify
  the behavior of concurrency limits before implementation.

  ## Test Categories

  1. Limit enforcement for max_parallel_sessions
  2. Limit enforcement for max_parallel_runs
  3. Clear error messages when limits are exceeded
  4. Tracking and releasing resources
  """

  use ExUnit.Case, async: true

  alias AgentSessionManager.Concurrency.ConcurrencyLimiter
  alias AgentSessionManager.Core.Error

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Start a fresh limiter for each test
    {:ok, limiter} =
      ConcurrencyLimiter.start_link(
        max_parallel_sessions: 3,
        max_parallel_runs: 5
      )

    on_exit(fn ->
      if Process.alive?(limiter), do: GenServer.stop(limiter)
    end)

    {:ok, limiter: limiter}
  end

  # ============================================================================
  # Configuration Tests
  # ============================================================================

  describe "start_link/1" do
    test "starts with configured limits" do
      {:ok, limiter} =
        ConcurrencyLimiter.start_link(
          max_parallel_sessions: 10,
          max_parallel_runs: 20
        )

      limits = ConcurrencyLimiter.get_limits(limiter)

      assert limits.max_parallel_sessions == 10
      assert limits.max_parallel_runs == 20

      GenServer.stop(limiter)
    end

    test "uses default limits when not specified" do
      {:ok, limiter} = ConcurrencyLimiter.start_link([])

      limits = ConcurrencyLimiter.get_limits(limiter)

      # Default limits should be reasonable
      assert limits.max_parallel_sessions > 0
      assert limits.max_parallel_runs > 0

      GenServer.stop(limiter)
    end

    test "allows unlimited sessions when set to :infinity" do
      {:ok, limiter} =
        ConcurrencyLimiter.start_link(
          max_parallel_sessions: :infinity,
          max_parallel_runs: 10
        )

      limits = ConcurrencyLimiter.get_limits(limiter)

      assert limits.max_parallel_sessions == :infinity
      assert limits.max_parallel_runs == 10

      GenServer.stop(limiter)
    end
  end

  # ============================================================================
  # Session Limit Enforcement Tests
  # ============================================================================

  describe "acquire_session_slot/2" do
    test "allows acquiring a session slot when under limit", %{limiter: limiter} do
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
    end

    test "allows acquiring multiple session slots up to limit", %{limiter: limiter} do
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")
    end

    test "returns error when session limit is reached", %{limiter: limiter} do
      # Fill up to the limit (3 sessions)
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")

      # Attempt to exceed the limit
      result = ConcurrencyLimiter.acquire_session_slot(limiter, "session-4")

      assert {:error, %Error{code: :max_sessions_exceeded}} = result
    end

    test "returns descriptive error message when limit exceeded", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")

      {:error, error} = ConcurrencyLimiter.acquire_session_slot(limiter, "session-4")

      assert error.message =~ "Maximum parallel sessions limit"
      # Should mention the limit
      assert error.message =~ "3"
    end

    test "is idempotent - same session can be acquired multiple times", %{limiter: limiter} do
      # Acquiring the same session twice should not count as two slots
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      # Should still have room for 2 more
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")
    end

    test "allows unlimited sessions when configured with :infinity" do
      {:ok, limiter} =
        ConcurrencyLimiter.start_link(
          max_parallel_sessions: :infinity,
          max_parallel_runs: 5
        )

      # Should be able to acquire many sessions
      for i <- 1..100 do
        assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-#{i}")
      end

      GenServer.stop(limiter)
    end
  end

  describe "release_session_slot/2" do
    test "releases a session slot allowing new sessions", %{limiter: limiter} do
      # Fill up
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-3")

      # Release one
      :ok = ConcurrencyLimiter.release_session_slot(limiter, "session-2")

      # Now should be able to acquire another
      assert :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-4")
    end

    test "is idempotent - releasing non-existent slot returns ok", %{limiter: limiter} do
      # Releasing a slot that was never acquired should not error
      assert :ok = ConcurrencyLimiter.release_session_slot(limiter, "non-existent")
    end

    test "releasing same slot multiple times is safe", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.release_session_slot(limiter, "session-1")
      assert :ok = ConcurrencyLimiter.release_session_slot(limiter, "session-1")
    end
  end

  # ============================================================================
  # Run Limit Enforcement Tests
  # ============================================================================

  describe "acquire_run_slot/3" do
    test "allows acquiring a run slot when under limit", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")
    end

    test "allows acquiring multiple run slots up to limit", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      for i <- 1..5 do
        assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
      end
    end

    test "returns error when run limit is reached", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      # Fill up to the run limit (5 runs)
      for i <- 1..5 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
      end

      # Attempt to exceed
      result = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-6")

      assert {:error, %Error{code: :max_runs_exceeded}} = result
    end

    test "returns descriptive error message when limit exceeded", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      for i <- 1..5 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
      end

      {:error, error} = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-6")

      assert error.message =~ "Maximum parallel runs limit"
      # Should mention the limit
      assert error.message =~ "5"
    end

    test "run limit applies globally, not per session", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")

      # 3 runs on session-1
      for i <- 1..3 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1-#{i}")
      end

      # 2 runs on session-2 (should hit limit at 5 total)
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-2", "run-2-1")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-2", "run-2-2")

      # 6th run should fail
      result = ConcurrencyLimiter.acquire_run_slot(limiter, "session-2", "run-2-3")
      assert {:error, %Error{code: :max_runs_exceeded}} = result
    end

    test "is idempotent - same run can be acquired multiple times", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")
      assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")

      # Should still have room for 4 more
      for i <- 2..5 do
        assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
      end
    end
  end

  describe "release_run_slot/2" do
    test "releases a run slot allowing new runs", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")

      # Fill up
      for i <- 1..5 do
        :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-#{i}")
      end

      # Release one
      :ok = ConcurrencyLimiter.release_run_slot(limiter, "run-3")

      # Now should be able to acquire another
      assert :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-6")
    end

    test "is idempotent - releasing non-existent run returns ok", %{limiter: limiter} do
      assert :ok = ConcurrencyLimiter.release_run_slot(limiter, "non-existent")
    end
  end

  # ============================================================================
  # Status and Metrics Tests
  # ============================================================================

  describe "get_status/1" do
    test "returns current usage", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-2")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")

      status = ConcurrencyLimiter.get_status(limiter)

      assert status.active_sessions == 2
      assert status.active_runs == 1
      assert status.max_parallel_sessions == 3
      assert status.max_parallel_runs == 5
    end

    test "returns available capacity", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-2")

      status = ConcurrencyLimiter.get_status(limiter)

      assert status.available_session_slots == 2
      assert status.available_run_slots == 3
    end
  end

  describe "session/run association" do
    test "releasing a session also releases its runs", %{limiter: limiter} do
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, "session-1")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-1")
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, "session-1", "run-2")

      # Verify runs are tracked
      status = ConcurrencyLimiter.get_status(limiter)
      assert status.active_runs == 2

      # Release the session
      :ok = ConcurrencyLimiter.release_session_slot(limiter, "session-1")

      # Runs should also be released
      status = ConcurrencyLimiter.get_status(limiter)
      assert status.active_runs == 0
      assert status.active_sessions == 0
    end
  end
end

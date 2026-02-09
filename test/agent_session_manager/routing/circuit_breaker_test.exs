defmodule AgentSessionManager.Routing.CircuitBreakerTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Routing.CircuitBreaker

  describe "new/1" do
    test "initializes in :closed state" do
      cb = CircuitBreaker.new()
      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.allowed?(cb) == true
    end

    test "accepts configuration options" do
      cb =
        CircuitBreaker.new(
          failure_threshold: 3,
          cooldown_ms: 5_000,
          half_open_max_probes: 2
        )

      assert CircuitBreaker.state(cb) == :closed
    end
  end

  describe "record_success/1" do
    test "resets failure count in :closed state" do
      cb =
        CircuitBreaker.new(failure_threshold: 3)
        |> CircuitBreaker.record_failure()
        |> CircuitBreaker.record_failure()
        |> CircuitBreaker.record_success()

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.failure_count(cb) == 0
    end

    test "transitions from :half_open to :closed on success" do
      cb =
        CircuitBreaker.new(failure_threshold: 2, cooldown_ms: 0)
        |> CircuitBreaker.record_failure()
        |> CircuitBreaker.record_failure()

      assert CircuitBreaker.state(cb) == :open

      # After cooldown, allow probe (transitions to half_open)
      Process.sleep(5)
      cb = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb) == :half_open

      cb = CircuitBreaker.record_success(cb)
      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.failure_count(cb) == 0
    end
  end

  describe "record_failure/1" do
    test "increments failure count in :closed state" do
      cb =
        CircuitBreaker.new(failure_threshold: 3)
        |> CircuitBreaker.record_failure()

      assert CircuitBreaker.state(cb) == :closed
      assert CircuitBreaker.failure_count(cb) == 1
    end

    test "transitions to :open when failure threshold reached" do
      cb =
        CircuitBreaker.new(failure_threshold: 2)
        |> CircuitBreaker.record_failure()
        |> CircuitBreaker.record_failure()

      assert CircuitBreaker.state(cb) == :open
    end

    test "transitions from :half_open back to :open on failure" do
      cb =
        CircuitBreaker.new(failure_threshold: 2, cooldown_ms: 0)
        |> CircuitBreaker.record_failure()
        |> CircuitBreaker.record_failure()

      Process.sleep(5)
      cb = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb) == :half_open

      cb = CircuitBreaker.record_failure(cb)
      assert CircuitBreaker.state(cb) == :open
    end
  end

  describe "allowed?/1" do
    test "returns true when :closed" do
      cb = CircuitBreaker.new()
      assert CircuitBreaker.allowed?(cb) == true
    end

    test "returns false when :open and within cooldown" do
      cb =
        CircuitBreaker.new(failure_threshold: 1, cooldown_ms: 60_000)
        |> CircuitBreaker.record_failure()

      assert CircuitBreaker.state(cb) == :open
      assert CircuitBreaker.allowed?(cb) == false
    end

    test "returns true when :open and cooldown expired (probe allowed)" do
      cb =
        CircuitBreaker.new(failure_threshold: 1, cooldown_ms: 0)
        |> CircuitBreaker.record_failure()

      Process.sleep(5)
      assert CircuitBreaker.allowed?(cb) == true
    end

    test "returns true when :half_open and probes remain" do
      cb =
        CircuitBreaker.new(failure_threshold: 1, cooldown_ms: 0, half_open_max_probes: 2)
        |> CircuitBreaker.record_failure()

      Process.sleep(5)
      cb = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb) == :half_open
      assert CircuitBreaker.allowed?(cb) == true
    end
  end

  describe "check_state/1" do
    test "transitions from :open to :half_open after cooldown" do
      cb =
        CircuitBreaker.new(failure_threshold: 1, cooldown_ms: 0)
        |> CircuitBreaker.record_failure()

      assert CircuitBreaker.state(cb) == :open

      Process.sleep(5)
      cb = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb) == :half_open
    end

    test "stays :open when cooldown has not expired" do
      cb =
        CircuitBreaker.new(failure_threshold: 1, cooldown_ms: 60_000)
        |> CircuitBreaker.record_failure()

      cb = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb) == :open
    end

    test "does nothing for :closed state" do
      cb = CircuitBreaker.new()
      cb2 = CircuitBreaker.check_state(cb)
      assert CircuitBreaker.state(cb2) == :closed
    end
  end

  describe "to_map/1" do
    test "returns a serializable summary" do
      cb = CircuitBreaker.new(failure_threshold: 3)
      summary = CircuitBreaker.to_map(cb)

      assert summary.state == :closed
      assert summary.failure_count == 0
      assert summary.failure_threshold == 3
    end
  end
end

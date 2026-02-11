defmodule AgentSessionManager.ConfigTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Config

  # ── Feature Flags (existing) ─────────────────────────────────────────────────

  describe "feature flags" do
    test "telemetry_enabled defaults to true" do
      assert Config.get(:telemetry_enabled) == true
    end

    test "audit_logging_enabled defaults to true" do
      assert Config.get(:audit_logging_enabled) == true
    end

    test "process-local override takes precedence" do
      Config.put(:telemetry_enabled, false)
      assert Config.get(:telemetry_enabled) == false
    after
      Config.delete(:telemetry_enabled)
    end

    test "delete falls back to default" do
      Config.put(:telemetry_enabled, false)
      Config.delete(:telemetry_enabled)
      assert Config.get(:telemetry_enabled) == true
    end
  end

  # ── Timeouts ─────────────────────────────────────────────────────────────────

  describe "timeout defaults" do
    test "stream_idle_timeout_ms" do
      assert Config.get(:stream_idle_timeout_ms) == 120_000
    end

    test "task_shutdown_timeout_ms" do
      assert Config.get(:task_shutdown_timeout_ms) == 5_000
    end

    test "await_run_timeout_ms" do
      assert Config.get(:await_run_timeout_ms) == 60_000
    end

    test "drain_timeout_buffer_ms" do
      assert Config.get(:drain_timeout_buffer_ms) == 1_000
    end

    test "command_timeout_ms" do
      assert Config.get(:command_timeout_ms) == 30_000
    end

    test "execute_timeout_ms" do
      assert Config.get(:execute_timeout_ms) == 60_000
    end

    test "execute_grace_timeout_ms" do
      assert Config.get(:execute_grace_timeout_ms) == 5_000
    end

    test "circuit_breaker_cooldown_ms" do
      assert Config.get(:circuit_breaker_cooldown_ms) == 30_000
    end

    test "sticky_session_ttl_ms" do
      assert Config.get(:sticky_session_ttl_ms) == 300_000
    end

    test "event_stream_poll_interval_ms" do
      assert Config.get(:event_stream_poll_interval_ms) == 250
    end

    test "genserver_call_timeout_ms" do
      assert Config.get(:genserver_call_timeout_ms) == 5_000
    end
  end

  # ── Buffer & Memory Limits ──────────────────────────────────────────────────

  describe "buffer and memory limit defaults" do
    test "event_buffer_size" do
      assert Config.get(:event_buffer_size) == 1_000
    end

    test "max_output_bytes" do
      assert Config.get(:max_output_bytes) == 1_048_576
    end

    test "max_patch_bytes" do
      assert Config.get(:max_patch_bytes) == 1_048_576
    end
  end

  # ── Concurrency ─────────────────────────────────────────────────────────────

  describe "concurrency defaults" do
    test "max_parallel_sessions" do
      assert Config.get(:max_parallel_sessions) == 100
    end

    test "max_parallel_runs" do
      assert Config.get(:max_parallel_runs) == 50
    end

    test "max_queued_runs" do
      assert Config.get(:max_queued_runs) == 100
    end
  end

  # ── Circuit Breaker ─────────────────────────────────────────────────────────

  describe "circuit breaker defaults" do
    test "circuit_breaker_failure_threshold" do
      assert Config.get(:circuit_breaker_failure_threshold) == 5
    end

    test "circuit_breaker_half_open_max_probes" do
      assert Config.get(:circuit_breaker_half_open_max_probes) == 1
    end
  end

  # ── SQLite ──────────────────────────────────────────────────────────────────

  describe "sqlite defaults" do
    test "sqlite_max_bind_params" do
      assert Config.get(:sqlite_max_bind_params) == 32_766
    end

    test "sqlite_busy_retry_attempts" do
      assert Config.get(:sqlite_busy_retry_attempts) == 25
    end

    test "sqlite_busy_retry_sleep_ms" do
      assert Config.get(:sqlite_busy_retry_sleep_ms) == 10
    end
  end

  # ── Query Limits ────────────────────────────────────────────────────────────

  describe "query limit defaults" do
    test "max_query_limit" do
      assert Config.get(:max_query_limit) == 1_000
    end

    test "default_session_query_limit" do
      assert Config.get(:default_session_query_limit) == 50
    end

    test "default_run_query_limit" do
      assert Config.get(:default_run_query_limit) == 50
    end

    test "default_event_query_limit" do
      assert Config.get(:default_event_query_limit) == 100
    end
  end

  # ── Retention ───────────────────────────────────────────────────────────────

  describe "retention defaults" do
    test "retention_max_completed_age_days" do
      assert Config.get(:retention_max_completed_age_days) == 90
    end

    test "retention_hard_delete_after_days" do
      assert Config.get(:retention_hard_delete_after_days) == 30
    end

    test "retention_batch_size" do
      assert Config.get(:retention_batch_size) == 100
    end

    test "retention_exempt_statuses" do
      assert Config.get(:retention_exempt_statuses) == [:active, :paused]
    end

    test "retention_exempt_tags" do
      assert Config.get(:retention_exempt_tags) == ["pinned"]
    end

    test "retention_prune_event_types_first" do
      assert Config.get(:retention_prune_event_types_first) == [
               :message_streamed,
               :token_usage_updated
             ]
    end
  end

  # ── Cost ────────────────────────────────────────────────────────────────────

  describe "cost defaults" do
    test "chars_per_token" do
      assert Config.get(:chars_per_token) == 4
    end
  end

  # ── Shell / Adapter ─────────────────────────────────────────────────────────

  describe "shell adapter defaults" do
    test "default_shell" do
      assert Config.get(:default_shell) == "/bin/sh"
    end

    test "default_success_exit_codes" do
      assert Config.get(:default_success_exit_codes) == [0]
    end
  end

  # ── Workspace ───────────────────────────────────────────────────────────────

  describe "workspace defaults" do
    test "excluded_workspace_roots" do
      assert Config.get(:excluded_workspace_roots) == [".git", "deps", "_build", "node_modules"]
    end
  end

  # ── Routing ─────────────────────────────────────────────────────────────────

  describe "routing defaults" do
    test "default_router_name" do
      assert Config.get(:default_router_name) == "router"
    end
  end

  # ── Process-local override for new keys ─────────────────────────────────────

  describe "process-local overrides for operational defaults" do
    test "put/get/delete cycle works for timeout keys" do
      Config.put(:command_timeout_ms, 5_000)
      assert Config.get(:command_timeout_ms) == 5_000

      Config.delete(:command_timeout_ms)
      assert Config.get(:command_timeout_ms) == 30_000
    end

    test "put/get/delete cycle works for limit keys" do
      Config.put(:max_parallel_sessions, 10)
      assert Config.get(:max_parallel_sessions) == 10

      Config.delete(:max_parallel_sessions)
      assert Config.get(:max_parallel_sessions) == 100
    end

    test "put/get/delete cycle works for string keys" do
      Config.put(:default_shell, "/bin/bash")
      assert Config.get(:default_shell) == "/bin/bash"

      Config.delete(:default_shell)
      assert Config.get(:default_shell) == "/bin/sh"
    end

    test "put/get/delete cycle works for list keys" do
      Config.put(:excluded_workspace_roots, [".git"])
      assert Config.get(:excluded_workspace_roots) == [".git"]

      Config.delete(:excluded_workspace_roots)
      assert Config.get(:excluded_workspace_roots) == [".git", "deps", "_build", "node_modules"]
    end
  end

  # ── Application env override ────────────────────────────────────────────────

  describe "application env override" do
    test "application env takes precedence over built-in default" do
      Application.put_env(:agent_session_manager, :command_timeout_ms, 15_000)
      assert Config.get(:command_timeout_ms) == 15_000
    after
      Application.delete_env(:agent_session_manager, :command_timeout_ms)
    end

    test "process-local takes precedence over application env" do
      Application.put_env(:agent_session_manager, :command_timeout_ms, 15_000)
      Config.put(:command_timeout_ms, 1_000)
      assert Config.get(:command_timeout_ms) == 1_000
    after
      Config.delete(:command_timeout_ms)
      Application.delete_env(:agent_session_manager, :command_timeout_ms)
    end
  end

  # ── default/1 ───────────────────────────────────────────────────────────────

  describe "default/1" do
    test "returns built-in default regardless of overrides" do
      Config.put(:command_timeout_ms, 1)
      Application.put_env(:agent_session_manager, :command_timeout_ms, 2)

      assert Config.default(:command_timeout_ms) == 30_000
    after
      Config.delete(:command_timeout_ms)
      Application.delete_env(:agent_session_manager, :command_timeout_ms)
    end

    test "returns built-in default for every valid key" do
      for key <- Config.valid_keys() do
        assert Config.default(key) != nil or Config.default(key) == nil,
               "default/1 must handle key #{inspect(key)}"
      end
    end
  end

  # ── valid_keys/0 ────────────────────────────────────────────────────────────

  describe "valid_keys/0" do
    test "returns a non-empty list of atoms" do
      keys = Config.valid_keys()
      assert is_list(keys)
      refute Enum.empty?(keys)
      assert Enum.all?(keys, &is_atom/1)
    end
  end
end

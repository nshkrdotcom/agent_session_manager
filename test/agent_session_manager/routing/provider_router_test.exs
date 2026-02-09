defmodule AgentSessionManager.Routing.ProviderRouterTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.{Capability, Error, Run, Session}
  alias AgentSessionManager.Ports.ProviderAdapter
  alias AgentSessionManager.Routing.ProviderRouter
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Test.RouterTestAdapter

  setup do
    session = build_session()
    run = build_run(session, "route this run")
    {:ok, session: session, run: run}
  end

  describe "execute/4 routing behavior" do
    test "routes by capability match and policy ordering", %{session: session, run: run} do
      {:ok, amp} =
        RouterTestAdapter.start_link(
          provider_name: "amp",
          capabilities: [%Capability{name: "bash", type: :tool, enabled: true}]
        )

      {:ok, codex} =
        RouterTestAdapter.start_link(
          provider_name: "codex",
          capabilities: [%Capability{name: "bash", type: :tool, enabled: true}]
        )

      {:ok, claude} =
        RouterTestAdapter.start_link(
          provider_name: "claude",
          capabilities: [%Capability{name: "chat", type: :tool, enabled: true}]
        )

      cleanup_on_exit(fn ->
        safe_stop(amp)
        safe_stop(codex)
        safe_stop(claude)
      end)

      {:ok, router} =
        ProviderRouter.start_link(
          policy: [prefer: ["claude", "amp", "codex"], exclude: ["claude"]]
        )

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "amp", amp)
      :ok = ProviderRouter.register_adapter(router, "codex", codex)
      :ok = ProviderRouter.register_adapter(router, "claude", claude)

      {:ok, result} =
        ProviderAdapter.execute(router, run, session,
          routing: [required_capabilities: [%{type: :tool, name: "bash"}]]
        )

      assert result.output.provider == "amp"
      assert RouterTestAdapter.execute_count(amp) == 1
      assert RouterTestAdapter.execute_count(codex) == 0
      assert RouterTestAdapter.execute_count(claude) == 0
    end

    test "fails over on retryable errors and records adapter health", %{
      session: session,
      run: run
    } do
      {:ok, primary} =
        RouterTestAdapter.start_link(
          provider_name: "primary",
          outcomes: [
            {:error, Error.new(:provider_timeout, "temporary timeout")}
          ]
        )

      {:ok, secondary} =
        RouterTestAdapter.start_link(provider_name: "secondary")

      cleanup_on_exit(fn ->
        safe_stop(primary)
        safe_stop(secondary)
      end)

      {:ok, router} =
        ProviderRouter.start_link(policy: [prefer: ["primary", "secondary"], max_attempts: 2])

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "primary", primary)
      :ok = ProviderRouter.register_adapter(router, "secondary", secondary)

      {:ok, result} = ProviderAdapter.execute(router, run, session, [])

      assert result.output.provider == "secondary"
      assert RouterTestAdapter.execute_count(primary) == 1
      assert RouterTestAdapter.execute_count(secondary) == 1

      status = ProviderRouter.status(router)

      assert status.health["primary"].failure_count == 1
      assert status.health["primary"].last_failure_at != nil
    end

    test "does not fail over on non-retryable errors", %{session: session, run: run} do
      {:ok, primary} =
        RouterTestAdapter.start_link(
          provider_name: "primary",
          outcomes: [
            {:error, Error.new(:provider_authentication_failed, "invalid credentials")}
          ]
        )

      {:ok, secondary} = RouterTestAdapter.start_link(provider_name: "secondary")

      cleanup_on_exit(fn ->
        safe_stop(primary)
        safe_stop(secondary)
      end)

      {:ok, router} =
        ProviderRouter.start_link(policy: [prefer: ["primary", "secondary"], max_attempts: 2])

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "primary", primary)
      :ok = ProviderRouter.register_adapter(router, "secondary", secondary)

      assert {:error, %Error{code: :provider_authentication_failed}} =
               ProviderAdapter.execute(router, run, session, [])

      assert RouterTestAdapter.execute_count(primary) == 1
      assert RouterTestAdapter.execute_count(secondary) == 0
    end

    test "skips unhealthy adapters during cooldown and retries after cooldown", %{
      session: session
    } do
      {:ok, primary} =
        RouterTestAdapter.start_link(
          provider_name: "primary",
          outcomes: [
            {:error, Error.new(:provider_unavailable, "temporary outage")},
            {:ok,
             %{
               output: %{provider: "primary", content: "recovered"},
               token_usage: %{input_tokens: 1, output_tokens: 1},
               events: []
             }}
          ]
        )

      {:ok, secondary} = RouterTestAdapter.start_link(provider_name: "secondary")

      cleanup_on_exit(fn ->
        safe_stop(primary)
        safe_stop(secondary)
      end)

      {:ok, router} =
        ProviderRouter.start_link(
          policy: [prefer: ["primary", "secondary"], max_attempts: 2],
          cooldown_ms: 200
        )

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "primary", primary)
      :ok = ProviderRouter.register_adapter(router, "secondary", secondary)

      run_1 = build_run(session, "first run")
      run_2 = build_run(session, "second run")
      run_3 = build_run(session, "third run")

      {:ok, first_result} = ProviderAdapter.execute(router, run_1, session, [])
      assert first_result.output.provider == "secondary"

      {:ok, second_result} = ProviderAdapter.execute(router, run_2, session, [])
      assert second_result.output.provider == "secondary"

      Process.sleep(250)

      {:ok, third_result} = ProviderAdapter.execute(router, run_3, session, [])
      assert third_result.output.provider == "primary"

      assert RouterTestAdapter.execute_count(primary) == 2
      assert RouterTestAdapter.execute_count(secondary) == 2
    end

    test "routes cancel/2 to the active adapter chosen for a run", %{session: session, run: run} do
      {:ok, primary} =
        RouterTestAdapter.start_link(
          provider_name: "primary",
          outcomes: [
            {:sleep, 2_000,
             {:ok,
              %{
                output: %{provider: "primary", content: "late success"},
                token_usage: %{input_tokens: 1, output_tokens: 1},
                events: []
              }}}
          ]
        )

      {:ok, secondary} = RouterTestAdapter.start_link(provider_name: "secondary")

      cleanup_on_exit(fn ->
        safe_stop(primary)
        safe_stop(secondary)
      end)

      {:ok, router} =
        ProviderRouter.start_link(policy: [prefer: ["primary", "secondary"], max_attempts: 1])

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "primary", primary)
      :ok = ProviderRouter.register_adapter(router, "secondary", secondary)

      execute_task = Task.async(fn -> ProviderAdapter.execute(router, run, session, []) end)

      # Allow time for the full routing chain: router task spawn → prepare_execution →
      # bind_run → adapter execute call → adapter task spawn → enter wait_for_cancellation
      Process.sleep(200)

      run_id = run.id

      assert {:ok, ^run_id} = ProviderAdapter.cancel(router, run_id)
      assert run_id in RouterTestAdapter.cancelled_runs(primary)
      refute run_id in RouterTestAdapter.cancelled_runs(secondary)

      assert {:error, %Error{code: :cancelled}} = Task.await(execute_task, 3_000)
    end
  end

  describe "weighted routing" do
    test "routes by weight when strategy is :weighted", %{session: session} do
      {:ok, amp} = RouterTestAdapter.start_link(provider_name: "amp")
      {:ok, codex} = RouterTestAdapter.start_link(provider_name: "codex")

      cleanup_on_exit(fn ->
        safe_stop(amp)
        safe_stop(codex)
      end)

      {:ok, router} =
        ProviderRouter.start_link(
          policy: [
            strategy: :weighted,
            weights: %{"amp" => 1, "codex" => 10},
            max_attempts: 1
          ]
        )

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "amp", amp)
      :ok = ProviderRouter.register_adapter(router, "codex", codex)

      run = build_run(session, "weighted run")
      {:ok, result} = ProviderAdapter.execute(router, run, session, [])

      assert result.output.provider == "codex"
    end
  end

  describe "session stickiness" do
    test "routes to the same adapter when sticky_session_id is provided", %{session: session} do
      {:ok, amp} = RouterTestAdapter.start_link(provider_name: "amp")
      {:ok, codex} = RouterTestAdapter.start_link(provider_name: "codex")

      cleanup_on_exit(fn ->
        safe_stop(amp)
        safe_stop(codex)
      end)

      {:ok, router} =
        ProviderRouter.start_link(
          policy: [prefer: ["amp", "codex"], max_attempts: 1],
          sticky_ttl_ms: 60_000
        )

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "amp", amp)
      :ok = ProviderRouter.register_adapter(router, "codex", codex)

      sticky_id = session.id

      # First run establishes stickiness
      run_1 = build_run(session, "first sticky run")

      {:ok, result_1} =
        ProviderAdapter.execute(router, run_1, session, routing: [sticky_session_id: sticky_id])

      first_provider = result_1.routing.routed_provider

      # Second run should use the same adapter
      run_2 = build_run(session, "second sticky run")

      {:ok, result_2} =
        ProviderAdapter.execute(router, run_2, session, routing: [sticky_session_id: sticky_id])

      assert result_2.routing.routed_provider == first_provider

      status = ProviderRouter.status(router)
      assert Map.has_key?(status.sticky_sessions, sticky_id)
    end
  end

  describe "circuit breaker" do
    test "blocks adapter after failure threshold when circuit_breaker: true", %{session: session} do
      {:ok, primary} =
        RouterTestAdapter.start_link(
          provider_name: "primary",
          outcomes: [
            {:error, Error.new(:provider_unavailable, "fail 1")},
            {:error, Error.new(:provider_unavailable, "fail 2")}
          ]
        )

      {:ok, secondary} = RouterTestAdapter.start_link(provider_name: "secondary")

      cleanup_on_exit(fn ->
        safe_stop(primary)
        safe_stop(secondary)
      end)

      {:ok, router} =
        ProviderRouter.start_link(
          policy: [prefer: ["primary", "secondary"], max_attempts: 2],
          circuit_breaker: true,
          circuit_breaker_opts: [failure_threshold: 2, cooldown_ms: 60_000],
          cooldown_ms: 0
        )

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "primary", primary)
      :ok = ProviderRouter.register_adapter(router, "secondary", secondary)

      # First run: primary fails, failover to secondary
      run_1 = build_run(session, "run 1")
      {:ok, result_1} = ProviderAdapter.execute(router, run_1, session, [])
      assert result_1.output.provider == "secondary"

      # Second run: primary fails again, reaching threshold
      run_2 = build_run(session, "run 2")
      {:ok, result_2} = ProviderAdapter.execute(router, run_2, session, [])
      assert result_2.output.provider == "secondary"

      # Third run: primary should be blocked by circuit breaker
      run_3 = build_run(session, "run 3")
      {:ok, result_3} = ProviderAdapter.execute(router, run_3, session, [])
      assert result_3.output.provider == "secondary"

      status = ProviderRouter.status(router)
      assert status.circuit_breakers["primary"].state == :open
    end
  end

  describe "SessionManager integration" do
    test "forwards adapter_opts routing hints through execute_run/4 and run_once/4", ctx do
      {:ok, store} = setup_test_store(ctx)

      {:ok, amp} =
        RouterTestAdapter.start_link(
          provider_name: "amp",
          capabilities: [%Capability{name: "chat", type: :tool, enabled: true}]
        )

      {:ok, codex} =
        RouterTestAdapter.start_link(
          provider_name: "codex",
          capabilities: [%Capability{name: "bash", type: :tool, enabled: true}]
        )

      cleanup_on_exit(fn ->
        safe_stop(amp)
        safe_stop(codex)
      end)

      {:ok, router} =
        ProviderRouter.start_link(policy: [prefer: ["amp", "codex"], max_attempts: 2])

      cleanup_on_exit(fn -> safe_stop(router) end)

      :ok = ProviderRouter.register_adapter(router, "amp", amp)
      :ok = ProviderRouter.register_adapter(router, "codex", codex)

      {:ok, session} = SessionManager.start_session(store, router, %{agent_id: "routing-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, router, session.id, %{prompt: "route me"})

      {:ok, routed_result} =
        SessionManager.execute_run(store, router, run.id,
          adapter_opts: [routing: [required_capabilities: [%{type: :tool, name: "bash"}]]]
        )

      assert routed_result.output.provider == "codex"

      {:ok, oneshot_result} =
        SessionManager.run_once(store, router, %{prompt: "one-shot routing"},
          adapter_opts: [routing: [required_capabilities: [%{type: :tool, name: "bash"}]]]
        )

      assert oneshot_result.output.provider == "codex"
    end
  end

  defp build_session do
    {:ok, session} = Session.new(%{agent_id: "routing-test"})
    session
  end

  defp build_run(session, prompt) do
    {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: prompt}})
    run
  end
end

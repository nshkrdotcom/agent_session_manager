defmodule AgentSessionManager.Policy.SessionManagerPolicyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Policy.Policy
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Test.RouterTestAdapter

  setup ctx do
    {:ok, store} = setup_test_store(ctx)

    {:ok, adapter} =
      RouterTestAdapter.start_link(provider_name: "policy-adapter")

    cleanup_on_exit(fn -> safe_stop(adapter) end)

    %{store: store, adapter: adapter}
  end

  describe "execute_run/4 with policy enforcement" do
    test "returns policy_violation error and cancels adapter for cancel-mode violations", %{
      store: store,
      adapter: adapter
    } do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "provider success"},
           token_usage: %{input_tokens: 12, output_tokens: 8},
           events: [
             %{type: :tool_call_started, data: %{tool_name: "bash"}}
           ]
         }}
      ])

      {:ok, policy} =
        Policy.new(
          name: "deny-shell",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "policy-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "run tools"})

      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.execute_run(store, adapter, run.id, policy: policy)

      assert run.id in RouterTestAdapter.cancelled_runs(adapter)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :policy_violation))

      {:ok, failed_run} = SessionStore.get_run(store, run.id)
      assert failed_run.status == :failed
      assert failed_run.error.code == :policy_violation
    end

    test "preserves successful result in warn mode and includes violation metadata", %{
      store: store,
      adapter: adapter
    } do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "provider success"},
           token_usage: %{input_tokens: 5, output_tokens: 5},
           events: [
             %{type: :tool_call_started, data: %{tool_name: "bash"}}
           ]
         }}
      ])

      {:ok, policy} =
        Policy.new(
          name: "warn-shell",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :warn
        )

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "policy-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "run tools"})

      assert {:ok, result} =
               SessionManager.execute_run(store, adapter, run.id, policy: policy)

      assert result.output.provider == "policy-adapter"
      assert is_map(result.policy)
      assert length(result.policy.violations) == 1
      assert result.policy.action == :warn

      refute run.id in RouterTestAdapter.cancelled_runs(adapter)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :policy_violation))

      {:ok, completed_run} = SessionStore.get_run(store, run.id)
      assert completed_run.status == :completed
    end
  end

  describe "run_once/4 with policy enforcement" do
    test "returns policy error on cancel-mode violations", %{store: store, adapter: adapter} do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "provider success"},
           token_usage: %{input_tokens: 20, output_tokens: 20},
           events: [
             %{type: :token_usage_updated, data: %{total_tokens: 40}}
           ]
         }}
      ])

      {:ok, policy} =
        Policy.new(
          name: "tiny-budget",
          limits: [{:max_total_tokens, 5}],
          on_violation: :cancel
        )

      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.run_once(store, adapter, %{prompt: "budget test"}, policy: policy)
    end
  end

  describe "execute_run/4 with :policies stack" do
    test "stacks multiple policies and enforces the merged result", %{
      store: store,
      adapter: adapter
    } do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "provider success"},
           token_usage: %{input_tokens: 12, output_tokens: 8},
           events: [
             %{type: :tool_call_started, data: %{tool_name: "bash"}}
           ]
         }}
      ])

      {:ok, org_policy} =
        Policy.new(
          name: "org",
          limits: [{:max_total_tokens, 100_000}],
          on_violation: :cancel
        )

      {:ok, team_policy} =
        Policy.new(
          name: "team",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :warn
        )

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "stack-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "stacked"})

      # The effective policy should have: org token limit + team deny bash + cancel (strictest)
      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.execute_run(store, adapter, run.id,
                 policies: [org_policy, team_policy]
               )

      assert run.id in RouterTestAdapter.cancelled_runs(adapter)
    end

    test ":policies takes precedence over :policy", %{store: store, adapter: adapter} do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "provider success"},
           token_usage: %{input_tokens: 5, output_tokens: 5},
           events: [
             %{type: :tool_call_started, data: %{tool_name: "bash"}}
           ]
         }}
      ])

      {:ok, single_policy} =
        Policy.new(
          name: "single",
          on_violation: :warn
        )

      {:ok, stack_policy} =
        Policy.new(
          name: "stack",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "prec-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "precedence"})

      # :policies should win over :policy
      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.execute_run(store, adapter, run.id,
                 policy: single_policy,
                 policies: [stack_policy]
               )
    end
  end

  describe "preflight checks" do
    test "rejects execution with impossible policy (empty allow list)", %{
      store: store,
      adapter: adapter
    } do
      {:ok, policy} =
        Policy.new(
          name: "impossible",
          tool_rules: [{:allow, []}],
          on_violation: :cancel
        )

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "pf-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "preflight"})

      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.execute_run(store, adapter, run.id, policy: policy)

      # Adapter should NOT have been called
      assert RouterTestAdapter.execute_count(adapter) == 0
    end
  end

  describe "run_once/4 with :policies stack" do
    test "supports policies stack via run_once", %{store: store, adapter: adapter} do
      RouterTestAdapter.set_outcomes(adapter, [
        {:ok,
         %{
           output: %{provider: "policy-adapter", content: "success"},
           token_usage: %{input_tokens: 5, output_tokens: 5},
           events: [
             %{type: :tool_call_started, data: %{tool_name: "bash"}}
           ]
         }}
      ])

      {:ok, org_policy} =
        Policy.new(
          name: "org",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      assert {:error, %Error{code: :policy_violation}} =
               SessionManager.run_once(store, adapter, %{prompt: "stack test"},
                 policies: [org_policy]
               )
    end
  end
end

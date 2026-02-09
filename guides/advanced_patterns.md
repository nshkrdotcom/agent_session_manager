# Advanced Patterns

This guide covers combining multiple features together. Each section shows a
realistic integration pattern with working code.

## Weighted Routing + Policy Stacks

Use weighted routing to prefer a provider while enforcing layered policies
from different organizational levels.

```elixir
alias AgentSessionManager.Routing.ProviderRouter
alias AgentSessionManager.Policy.Policy
alias AgentSessionManager.SessionManager

# Set up weighted router
{:ok, router} =
  ProviderRouter.start_link(
    policy: [
      strategy: :weighted,
      weights: %{"claude" => 10, "codex" => 3, "amp" => 1},
      max_attempts: 3
    ],
    circuit_breaker_enabled: true,
    circuit_breaker_opts: [failure_threshold: 5, cooldown_ms: 30_000]
  )

:ok = ProviderRouter.register_adapter(router, "claude", claude_adapter)
:ok = ProviderRouter.register_adapter(router, "codex", codex_adapter)
:ok = ProviderRouter.register_adapter(router, "amp", amp_adapter)

# Define layered policies
{:ok, org_policy} =
  Policy.new(
    name: "org",
    limits: [{:max_total_tokens, 100_000}, {:max_cost_usd, 0.50}],
    on_violation: :cancel
  )

{:ok, team_policy} =
  Policy.new(
    name: "team",
    tool_rules: [{:deny, ["bash", "shell"]}],
    limits: [{:max_duration_ms, 60_000}],
    on_violation: :warn
  )

# Execute with routing + stacked policies
{:ok, result} =
  SessionManager.execute_run(store, router, run.id,
    policies: [org_policy, team_policy],
    adapter_opts: [
      routing: [
        required_capabilities: [%{type: :tool, name: "read"}]
      ]
    ]
  )

# The router selects the best provider by weight (preferring claude),
# the merged policy enforces org token limits (cancel) + team tool
# restrictions (warn), and provider-side enforcement compiles deny
# rules into adapter_opts for the selected provider.
```

## SessionServer + Durable Subscriptions + Workspace Snapshots

Run a long-lived session server with concurrent slots, durable event
subscriptions for a streaming UI, and workspace snapshots per run.

```elixir
alias AgentSessionManager.Runtime.SessionServer

{:ok, server} =
  SessionServer.start_link(
    store: store,
    adapter: adapter,
    session_opts: %{agent_id: "workspace-agent"},
    max_concurrent_runs: 2,
    default_execute_opts: [
      continuation: :auto,
      continuation_opts: [max_messages: 200, max_tokens_approx: 8_000],
      workspace: [
        enabled: true,
        path: "/home/user/project",
        strategy: :git,
        capture_patch: true,
        max_patch_bytes: 1_048_576,
        artifact_store: artifact_store,
        rollback_on_failure: true
      ]
    ]
  )

# Subscribe for streaming UI (durable -- can resume from cursor)
{:ok, ref} = SessionServer.subscribe(server, from_sequence: 0)

# Submit two runs that execute concurrently
{:ok, r1} = SessionServer.submit_run(server, %{messages: [%{role: "user", content: "Add tests"}]})
{:ok, r2} = SessionServer.submit_run(server, %{messages: [%{role: "user", content: "Fix lint"}]})

# Process interleaved events from both runs
defmodule StreamHandler do
  def loop(last_seq) do
    receive do
      {:session_event, _session_id, event} ->
        handle_event(event)
        loop(event.sequence_number)
    after
      30_000 -> {:ok, last_seq}
    end
  end

  defp handle_event(%{type: :workspace_diff_computed} = event) do
    IO.puts("Workspace: #{event.data.files_changed} files changed (run #{event.run_id})")
  end

  defp handle_event(%{type: :message_streamed} = event) do
    IO.write(event.data[:delta] || "")
  end

  defp handle_event(_event), do: :ok
end

# After disconnect, resume from saved cursor (no events missed)
# {:ok, ref} = SessionServer.subscribe(server, from_sequence: last_seq + 1)
```

## Routing + Stickiness + Continuity

Bind a session to a specific provider across runs using stickiness, while
maintaining transcript continuity for multi-turn conversations.

```elixir
alias AgentSessionManager.Routing.ProviderRouter
alias AgentSessionManager.SessionManager

{:ok, router} =
  ProviderRouter.start_link(
    policy: [prefer: ["claude", "codex", "amp"]],
    sticky_ttl_ms: 600_000  # 10 minutes
  )

:ok = ProviderRouter.register_adapter(router, "claude", claude_adapter)
:ok = ProviderRouter.register_adapter(router, "codex", codex_adapter)

# Create a session
{:ok, session} = SessionManager.start_session(store, router, %{agent_id: "sticky-agent"})
{:ok, session} = SessionManager.activate_session(store, session.id)

# Run 1 -- routes to preferred provider and binds the session
{:ok, run_1} = SessionManager.start_run(store, router, session.id, %{
  messages: [%{role: "user", content: "Remember: the code is X-42."}]
})

{:ok, _} = SessionManager.execute_run(store, router, run_1.id,
  continuation: :auto,
  adapter_opts: [routing: [sticky_session_id: session.id]]
)

# Run 2 -- same provider (sticky), with transcript from run 1
{:ok, run_2} = SessionManager.start_run(store, router, session.id, %{
  messages: [%{role: "user", content: "What was the code?"}]
})

{:ok, result} = SessionManager.execute_run(store, router, run_2.id,
  continuation: :auto,
  continuation_opts: [max_messages: 100],
  adapter_opts: [routing: [sticky_session_id: session.id]]
)

# result.output.content should recall "X-42" because:
# 1. Stickiness ensured the same provider handled both runs
# 2. Continuation injected the transcript from run 1
```

## Policy + Workspace + Artifact Store

Enforce cost and tool policies while capturing workspace diffs with
artifact-backed patch storage.

```elixir
alias AgentSessionManager.Policy.Policy
alias AgentSessionManager.Adapters.FileArtifactStore

{:ok, artifact_store} = FileArtifactStore.start_link(root: "/tmp/artifacts")

{:ok, policy} =
  Policy.new(
    name: "safe-workspace",
    limits: [{:max_total_tokens, 50_000}, {:max_tool_calls, 10}],
    tool_rules: [{:deny, ["rm", "delete"]}],
    on_violation: :cancel
  )

{:ok, result} =
  SessionManager.execute_run(store, adapter, run.id,
    policy: policy,
    workspace: [
      enabled: true,
      path: "/home/user/project",
      strategy: :git,
      capture_patch: true,
      max_patch_bytes: 2_097_152,
      artifact_store: artifact_store,
      rollback_on_failure: true
    ]
  )

case result do
  %{workspace: %{diff: %{patch_ref: ref}}} when not is_nil(ref) ->
    # Retrieve the full patch from artifact storage
    {:ok, patch} = ArtifactStore.get(artifact_store, ref)
    IO.puts("Patch size: #{byte_size(patch)} bytes")

  %{workspace: %{diff: %{has_patch: true, patch: patch}}} ->
    # Small patch was embedded directly
    IO.puts("Inline patch: #{byte_size(patch)} bytes")

  _ ->
    IO.puts("No workspace changes")
end

# If the policy violation triggered cancellation, rollback_on_failure
# reverts workspace changes to the pre-run snapshot automatically.
```

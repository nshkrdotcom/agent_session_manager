defmodule AgentSessionManager.Ports.MaintenanceTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Persistence.RetentionPolicy
  alias AgentSessionManager.Ports.Maintenance

  defmodule DummyMaintenance do
    def execute(_ctx, _policy) do
      {:ok,
       %{
         sessions_soft_deleted: 0,
         sessions_hard_deleted: 0,
         events_pruned: 0,
         artifacts_cleaned: 0,
         orphaned_sequences_cleaned: 0,
         duration_ms: 0,
         errors: []
       }}
    end

    def prune_session_events(_ctx, _session_id, _policy), do: {:ok, 0}
    def soft_delete_expired_sessions(_ctx, _policy), do: {:ok, 0}
    def hard_delete_expired_sessions(_ctx, _policy), do: {:ok, 0}
    def clean_orphaned_artifacts(_ctx, _opts), do: {:ok, 0}
    def health_check(_ctx), do: {:ok, []}
  end

  test "dispatches module-backed refs" do
    policy = RetentionPolicy.new(max_completed_session_age_days: 90)

    assert {:ok, %{sessions_soft_deleted: 0}} =
             Maintenance.execute({DummyMaintenance, :ctx}, policy)
  end

  test "rejects non-module maintenance refs" do
    policy = RetentionPolicy.new(max_completed_session_age_days: 90)
    assert {:error, %Error{code: :validation_error}} = Maintenance.execute(self(), policy)
  end
end

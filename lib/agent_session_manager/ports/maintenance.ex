defmodule AgentSessionManager.Ports.Maintenance do
  @moduledoc """
  Port for database maintenance operations.

  Provides retention enforcement, event pruning, and data integrity checks.
  Maintenance is never automatically scheduled — the application must call
  it explicitly (e.g., via a mix task, GenServer timer, or job scheduler).

  ## Usage

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, report} = Maintenance.execute(store, policy)

  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Persistence.RetentionPolicy

  @type store :: GenServer.server() | pid() | atom()

  @type maintenance_report :: %{
          sessions_soft_deleted: non_neg_integer(),
          sessions_hard_deleted: non_neg_integer(),
          events_pruned: non_neg_integer(),
          artifacts_cleaned: non_neg_integer(),
          orphaned_sequences_cleaned: non_neg_integer(),
          duration_ms: non_neg_integer(),
          errors: [String.t()]
        }

  @doc """
  Execute retention policy against the store.

  Performs all applicable maintenance operations based on the policy.
  """
  @callback execute(store(), RetentionPolicy.t()) ::
              {:ok, maintenance_report()} | {:error, Error.t()}

  @doc """
  Prune events for a single session based on policy.
  """
  @callback prune_session_events(store(), session_id :: String.t(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Soft-delete completed sessions older than the retention period.
  """
  @callback soft_delete_expired_sessions(store(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Hard-delete sessions that were soft-deleted longer ago than hard_delete_after_days.
  """
  @callback hard_delete_expired_sessions(store(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Clean up orphaned artifacts.
  """
  @callback clean_orphaned_artifacts(store(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Health check: verify data integrity.

  Returns a list of issue descriptions. Empty list means healthy.
  """
  @callback health_check(store()) ::
              {:ok, [String.t()]} | {:error, Error.t()}

  # ============================================================================
  # Dispatch functions
  # ============================================================================

  @spec execute(store(), RetentionPolicy.t()) ::
          {:ok, maintenance_report()} | {:error, Error.t()}
  def execute(store, policy) do
    GenServer.call(store, {:maintenance_execute, policy}, 60_000)
  end

  @spec prune_session_events(store(), String.t(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def prune_session_events(store, session_id, policy) do
    GenServer.call(store, {:maintenance_prune_events, session_id, policy})
  end

  @spec soft_delete_expired_sessions(store(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def soft_delete_expired_sessions(store, policy) do
    GenServer.call(store, {:maintenance_soft_delete_expired, policy})
  end

  @spec hard_delete_expired_sessions(store(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def hard_delete_expired_sessions(store, policy) do
    GenServer.call(store, {:maintenance_hard_delete_expired, policy})
  end

  @spec clean_orphaned_artifacts(store(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def clean_orphaned_artifacts(store, opts \\ []) do
    GenServer.call(store, {:maintenance_clean_artifacts, opts})
  end

  @spec health_check(store()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def health_check(store) do
    GenServer.call(store, {:maintenance_health_check})
  end
end

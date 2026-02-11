defmodule AgentSessionManager.Ports.Maintenance do
  @moduledoc """
  Port for database maintenance operations.

  Provides retention enforcement, event pruning, and data integrity checks.
  Maintenance is never automatically scheduled — the application must call
  it explicitly (e.g., via a mix task, GenServer timer, or job scheduler).

  ## Usage

      policy = RetentionPolicy.new(max_completed_session_age_days: 90)
      {:ok, report} = Maintenance.execute({EctoMaintenance, MyApp.Repo}, policy)

  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Persistence.RetentionPolicy

  @type context :: term()
  @type maintenance_ref :: {module(), context()}

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
  @callback execute(context(), RetentionPolicy.t()) ::
              {:ok, maintenance_report()} | {:error, Error.t()}

  @doc """
  Prune events for a single session based on policy.
  """
  @callback prune_session_events(context(), session_id :: String.t(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Soft-delete completed sessions older than the retention period.
  """
  @callback soft_delete_expired_sessions(context(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Hard-delete sessions that were soft-deleted longer ago than hard_delete_after_days.
  """
  @callback hard_delete_expired_sessions(context(), RetentionPolicy.t()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Clean up orphaned artifacts.
  """
  @callback clean_orphaned_artifacts(context(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  @doc """
  Health check: verify data integrity.

  Returns a list of issue descriptions. Empty list means healthy.
  """
  @callback health_check(context()) ::
              {:ok, [String.t()]} | {:error, Error.t()}

  # ============================================================================
  # Dispatch functions (module-backed refs only)
  # ============================================================================

  @spec execute(maintenance_ref(), RetentionPolicy.t()) ::
          {:ok, maintenance_report()} | {:error, Error.t()}
  def execute(maintenance_ref, policy) do
    dispatch(maintenance_ref, :execute, [policy])
  end

  @spec prune_session_events(maintenance_ref(), String.t(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def prune_session_events(maintenance_ref, session_id, policy) do
    dispatch(maintenance_ref, :prune_session_events, [session_id, policy])
  end

  @spec soft_delete_expired_sessions(maintenance_ref(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def soft_delete_expired_sessions(maintenance_ref, policy) do
    dispatch(maintenance_ref, :soft_delete_expired_sessions, [policy])
  end

  @spec hard_delete_expired_sessions(maintenance_ref(), RetentionPolicy.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def hard_delete_expired_sessions(maintenance_ref, policy) do
    dispatch(maintenance_ref, :hard_delete_expired_sessions, [policy])
  end

  @spec clean_orphaned_artifacts(maintenance_ref(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def clean_orphaned_artifacts(maintenance_ref, opts \\ []) do
    dispatch(maintenance_ref, :clean_orphaned_artifacts, [opts])
  end

  @spec health_check(maintenance_ref()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def health_check(maintenance_ref) do
    dispatch(maintenance_ref, :health_check, [])
  end

  defp dispatch({module, context}, function_name, args) when is_atom(module) do
    apply(module, function_name, [context | args])
  end

  defp dispatch(maintenance_ref, _function_name, _args) do
    {:error,
     Error.new(
       :validation_error,
       "Maintenance ref must be {module, context}, got: #{inspect(maintenance_ref)}"
     )}
  end
end

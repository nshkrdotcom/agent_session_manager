defmodule AgentSessionManager.Ports.QueryAPI do
  @moduledoc """
  Read-only query interface for historical session data.

  Provides cross-session search, aggregation, and export capabilities
  beyond the single-session cursor reads in SessionStore.

  ## Callbacks

  - `search_sessions/2` — Search sessions with filters and cursor pagination
  - `get_session_stats/2` — Aggregate statistics for a session
  - `search_runs/2` — Search runs across sessions
  - `get_usage_summary/2` — Token usage summary by provider
  - `search_events/2` — Search events across sessions
  - `count_events/2` — Count events matching filters
  - `export_session/3` — Export complete session data

  ## Usage

      {:ok, %{sessions: sessions, cursor: cursor}} =
        QueryAPI.search_sessions(store, agent_id: "agent-1", limit: 20)

      {:ok, stats} = QueryAPI.get_session_stats(store, "ses_abc123")

  """

  alias AgentSessionManager.Core.{Error, Event, Run, Session}

  @type store :: GenServer.server() | pid() | atom()
  @type cursor :: String.t() | nil

  # ============================================================================
  # Session Queries
  # ============================================================================

  @doc """
  Search sessions with rich filters.

  ## Options

  - `:agent_id` — filter by agent
  - `:status` — filter by status (atom or list)
  - `:provider` — filter by provider that executed runs in this session
  - `:tags` — filter by tags (all must match)
  - `:created_after` — sessions created after this DateTime
  - `:created_before` — sessions created before this DateTime
  - `:include_deleted` — include soft-deleted sessions (default: false)
  - `:order_by` — `:created_at_asc` | `:created_at_desc` | `:updated_at_desc` (default)
  - `:limit` — max results (default: 50)
  - `:cursor` — opaque cursor from previous page
  """
  @callback search_sessions(store(), keyword()) ::
              {:ok,
               %{
                 sessions: [Session.t()],
                 cursor: cursor(),
                 total_count: non_neg_integer()
               }}
              | {:error, Error.t()}

  @doc """
  Get aggregate statistics for a session.

  Returns a map with:
  - `event_count` — total events
  - `run_count` — total runs
  - `token_totals` — `%{input_tokens: n, output_tokens: n, total_tokens: n}`
  - `providers_used` — list of provider names
  - `first_event_at` — earliest event timestamp
  - `last_event_at` — latest event timestamp
  - `status_counts` — `%{completed: 3, failed: 1, ...}` (run statuses)
  """
  @callback get_session_stats(store(), session_id :: String.t()) ::
              {:ok, map()} | {:error, Error.t()}

  # ============================================================================
  # Run Queries
  # ============================================================================

  @doc """
  Search runs across sessions.

  ## Options

  - `:session_id` — scope to single session
  - `:provider` — filter by provider
  - `:status` — filter by status
  - `:started_after` — runs started after this DateTime
  - `:started_before` — runs started before this DateTime
  - `:min_tokens` — minimum total_tokens
  - `:order_by` — `:started_at_desc` (default) | `:started_at_asc` | `:token_usage_desc`
  - `:limit` — max results (default: 50)
  - `:cursor` — opaque cursor from previous page
  """
  @callback search_runs(store(), keyword()) ::
              {:ok, %{runs: [Run.t()], cursor: cursor()}} | {:error, Error.t()}

  @doc """
  Get token usage summary across runs.

  ## Options

  - `:session_id` — scope to session
  - `:provider` — filter by provider
  - `:since` — DateTime lower bound
  - `:until` — DateTime upper bound

  Returns a map with:
  - `total_input_tokens` — integer
  - `total_output_tokens` — integer
  - `total_tokens` — integer
  - `run_count` — integer
  - `by_provider` — `%{"claude" => %{...}, "codex" => %{...}}`
  """
  @callback get_usage_summary(store(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  # ============================================================================
  # Event Queries
  # ============================================================================

  @doc """
  Search events across sessions with rich filters.

  ## Options

  - `:session_ids` — list of session IDs
  - `:run_ids` — filter by specific runs
  - `:types` — filter by event types (atom or list)
  - `:providers` — filter by provider
  - `:since` — events after this DateTime
  - `:until` — events before this DateTime
  - `:correlation_id` — filter by correlation ID
  - `:order_by` — `:sequence_asc` (default) | `:timestamp_asc` | `:timestamp_desc`
  - `:limit` — max results (default: 100)
  - `:cursor` — opaque cursor from previous page
  """
  @callback search_events(store(), keyword()) ::
              {:ok, %{events: [Event.t()], cursor: cursor()}} | {:error, Error.t()}

  @doc """
  Count events matching filters without loading them.

  Same filter options as `search_events/2`.
  """
  @callback count_events(store(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}

  # ============================================================================
  # Export
  # ============================================================================

  @doc """
  Export a session's complete data (session + runs + events) as a map.

  ## Options

  - `:include_artifacts` — include artifact metadata (default: false)
  """
  @callback export_session(store(), session_id :: String.t(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  # ============================================================================
  # Dispatch functions
  # ============================================================================

  @spec search_sessions(store(), keyword()) ::
          {:ok, %{sessions: [Session.t()], cursor: cursor(), total_count: non_neg_integer()}}
          | {:error, Error.t()}
  def search_sessions(store, opts \\ []) do
    GenServer.call(store, {:search_sessions, opts})
  end

  @spec get_session_stats(store(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_session_stats(store, session_id) do
    GenServer.call(store, {:get_session_stats, session_id})
  end

  @spec search_runs(store(), keyword()) ::
          {:ok, %{runs: [Run.t()], cursor: cursor()}} | {:error, Error.t()}
  def search_runs(store, opts \\ []) do
    GenServer.call(store, {:search_runs, opts})
  end

  @spec get_usage_summary(store(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_usage_summary(store, opts \\ []) do
    GenServer.call(store, {:get_usage_summary, opts})
  end

  @spec search_events(store(), keyword()) ::
          {:ok, %{events: [Event.t()], cursor: cursor()}} | {:error, Error.t()}
  def search_events(store, opts \\ []) do
    GenServer.call(store, {:search_events, opts})
  end

  @spec count_events(store(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def count_events(store, opts \\ []) do
    GenServer.call(store, {:count_events, opts})
  end

  @spec export_session(store(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def export_session(store, session_id, opts \\ []) do
    GenServer.call(store, {:export_session, session_id, opts})
  end
end

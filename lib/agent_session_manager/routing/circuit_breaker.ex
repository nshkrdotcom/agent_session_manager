defmodule AgentSessionManager.Routing.CircuitBreaker do
  @moduledoc """
  Pure-functional circuit breaker for provider health tracking.

  The circuit breaker maintains three states:

  - `:closed` — normal operation; requests are allowed.
  - `:open` — too many failures; requests are blocked until cooldown expires.
  - `:half_open` — cooldown expired; limited probe requests are allowed to
    test recovery.

  ## State Transitions

      :closed --(failure threshold reached)--> :open
      :open   --(cooldown expires)-----------> :half_open
      :half_open --(probe succeeds)----------> :closed
      :half_open --(probe fails)-------------> :open

  ## Usage

  This module is a pure data structure with no side effects or processes.
  It is intended to be stored in router state per adapter.

      cb = CircuitBreaker.new(failure_threshold: 3, cooldown_ms: 30_000)
      cb = CircuitBreaker.record_failure(cb)
      CircuitBreaker.allowed?(cb)  # true (still below threshold)

  ## Configuration

  - `failure_threshold` — number of consecutive failures to trigger open state
    (default: `5`)
  - `cooldown_ms` — how long to stay open before transitioning to half-open
    (default: `30_000`)
  - `half_open_max_probes` — probe attempts allowed in half-open before
    requiring success or reopening (default: `1`)
  """

  @default_failure_threshold 5
  @default_cooldown_ms 30_000
  @default_half_open_max_probes 1

  @type state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          state: state(),
          failure_count: non_neg_integer(),
          failure_threshold: pos_integer(),
          cooldown_ms: non_neg_integer(),
          half_open_max_probes: pos_integer(),
          half_open_probe_count: non_neg_integer(),
          opened_at_ms: integer() | nil
        }

  @enforce_keys []
  defstruct state: :closed,
            failure_count: 0,
            failure_threshold: @default_failure_threshold,
            cooldown_ms: @default_cooldown_ms,
            half_open_max_probes: @default_half_open_max_probes,
            half_open_probe_count: 0,
            opened_at_ms: nil

  @doc """
  Creates a new circuit breaker in `:closed` state.

  ## Options

  - `:failure_threshold` — failures before opening (default: `5`)
  - `:cooldown_ms` — cooldown period in milliseconds (default: `30_000`)
  - `:half_open_max_probes` — max probes in half-open (default: `1`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      failure_threshold: normalize_pos_int(opts[:failure_threshold], @default_failure_threshold),
      cooldown_ms: normalize_non_neg_int(opts[:cooldown_ms], @default_cooldown_ms),
      half_open_max_probes:
        normalize_pos_int(opts[:half_open_max_probes], @default_half_open_max_probes)
    }
  end

  @doc """
  Returns the current circuit breaker state.
  """
  @spec state(t()) :: state()
  def state(%__MODULE__{state: s}), do: s

  @doc """
  Returns the current failure count.
  """
  @spec failure_count(t()) :: non_neg_integer()
  def failure_count(%__MODULE__{failure_count: c}), do: c

  @doc """
  Returns whether a request is allowed through the circuit breaker.

  - `:closed` — always allowed
  - `:open` — allowed only if cooldown has expired (probe)
  - `:half_open` — allowed if probe count is below max
  """
  @spec allowed?(t()) :: boolean()
  def allowed?(%__MODULE__{state: :closed}), do: true

  def allowed?(%__MODULE__{state: :open} = cb) do
    cooldown_expired?(cb)
  end

  def allowed?(%__MODULE__{state: :half_open} = cb) do
    cb.half_open_probe_count < cb.half_open_max_probes
  end

  @doc """
  Checks and potentially transitions the state based on elapsed time.

  - `:open` with expired cooldown → `:half_open`
  - All other states → no change
  """
  @spec check_state(t()) :: t()
  def check_state(%__MODULE__{state: :open} = cb) do
    if cooldown_expired?(cb) do
      %{cb | state: :half_open, half_open_probe_count: 0}
    else
      cb
    end
  end

  def check_state(%__MODULE__{} = cb), do: cb

  @doc """
  Records a successful request.

  - `:closed` — resets failure count
  - `:half_open` — transitions to `:closed`
  - `:open` — resets to `:closed` (unexpected but safe)
  """
  @spec record_success(t()) :: t()
  def record_success(%__MODULE__{} = cb) do
    %{cb | state: :closed, failure_count: 0, opened_at_ms: nil, half_open_probe_count: 0}
  end

  @doc """
  Records a failed request.

  - `:closed` — increments failure count; opens if threshold reached
  - `:half_open` — reopens immediately
  - `:open` — stays open (no-op)
  """
  @spec record_failure(t()) :: t()
  def record_failure(%__MODULE__{state: :closed} = cb) do
    new_count = cb.failure_count + 1

    if new_count >= cb.failure_threshold do
      %{cb | state: :open, failure_count: new_count, opened_at_ms: now_ms()}
    else
      %{cb | failure_count: new_count}
    end
  end

  def record_failure(%__MODULE__{state: :half_open} = cb) do
    %{cb | state: :open, opened_at_ms: now_ms(), half_open_probe_count: 0}
  end

  def record_failure(%__MODULE__{state: :open} = cb) do
    %{cb | failure_count: cb.failure_count + 1, opened_at_ms: now_ms()}
  end

  @doc """
  Returns a map summary of the circuit breaker state.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = cb) do
    %{
      state: cb.state,
      failure_count: cb.failure_count,
      failure_threshold: cb.failure_threshold,
      cooldown_ms: cb.cooldown_ms,
      half_open_max_probes: cb.half_open_max_probes,
      half_open_probe_count: cb.half_open_probe_count
    }
  end

  # ------------------------------------------------------------------
  # Private
  # ------------------------------------------------------------------

  defp cooldown_expired?(%__MODULE__{opened_at_ms: nil}), do: true

  defp cooldown_expired?(%__MODULE__{opened_at_ms: opened_at, cooldown_ms: cooldown}) do
    now_ms() - opened_at >= cooldown
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp normalize_pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_pos_int(_value, default), do: default

  defp normalize_non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_int(_value, default), do: default
end

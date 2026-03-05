defmodule ASM.Extensions.Routing.HealthTracker do
  @moduledoc """
  Provider health state machine with temporary exclusion windows.
  """

  alias ASM.Error

  @typedoc "Unique provider candidate identifier used by the router."
  @type provider_id :: term()

  @typedoc "Per-provider health status."
  @type health_status :: %{
          status: :healthy | :degraded | :unhealthy,
          failures: non_neg_integer(),
          last_error: term() | nil,
          excluded_until_ms: integer() | nil,
          excluded?: boolean()
        }

  @typep tracker_state :: %{
           required(:status) => :healthy | :degraded | :unhealthy,
           required(:failures) => non_neg_integer(),
           required(:last_error) => term() | nil,
           required(:excluded_until_ms) => integer() | nil
         }

  @type t :: %__MODULE__{
          by_provider: %{provider_id() => tracker_state()},
          failure_cooldown_ms: pos_integer()
        }

  @enforce_keys [:by_provider, :failure_cooldown_ms]
  defstruct [:by_provider, :failure_cooldown_ms]

  @spec new([provider_id()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(provider_ids, opts \\ []) when is_list(provider_ids) and is_list(opts) do
    cooldown = Keyword.get(opts, :failure_cooldown_ms, 30_000)

    cond do
      provider_ids == [] ->
        {:error, config_error("routing requires at least one provider candidate")}

      not is_integer(cooldown) or cooldown <= 0 ->
        {:error, config_error(":failure_cooldown_ms must be a positive integer")}

      true ->
        by_provider =
          provider_ids
          |> Enum.uniq()
          |> Enum.reduce(%{}, fn provider_id, acc ->
            Map.put(acc, provider_id, fresh_state())
          end)

        {:ok, %__MODULE__{by_provider: by_provider, failure_cooldown_ms: cooldown}}
    end
  end

  @spec refresh(t(), integer()) :: t()
  def refresh(%__MODULE__{} = tracker, now_ms) when is_integer(now_ms) do
    by_provider =
      Enum.into(tracker.by_provider, %{}, fn {provider_id, state} ->
        {provider_id, maybe_recover_to_degraded(state, now_ms)}
      end)

    %{tracker | by_provider: by_provider}
  end

  @spec mark_success(t(), provider_id(), integer()) :: {:ok, t()} | {:error, Error.t()}
  def mark_success(%__MODULE__{} = tracker, provider_id, now_ms) when is_integer(now_ms) do
    with {:ok, state} <- fetch_state(tracker, provider_id) do
      recovered = maybe_recover_to_degraded(state, now_ms)

      next_state = %{
        recovered
        | status: :healthy,
          failures: 0,
          last_error: nil,
          excluded_until_ms: nil
      }

      {:ok, put_state(tracker, provider_id, next_state)}
    end
  end

  @spec mark_failure(t(), provider_id(), term(), integer()) :: {:ok, t()} | {:error, Error.t()}
  def mark_failure(%__MODULE__{} = tracker, provider_id, reason, now_ms)
      when is_integer(now_ms) do
    with {:ok, state} <- fetch_state(tracker, provider_id) do
      current = maybe_recover_to_degraded(state, now_ms)

      next_state = %{
        current
        | status: :unhealthy,
          failures: current.failures + 1,
          last_error: reason,
          excluded_until_ms: now_ms + tracker.failure_cooldown_ms
      }

      {:ok, put_state(tracker, provider_id, next_state)}
    end
  end

  @spec status(t(), provider_id(), integer()) :: {:ok, health_status()} | {:error, Error.t()}
  def status(%__MODULE__{} = tracker, provider_id, now_ms) when is_integer(now_ms) do
    with {:ok, state} <- fetch_state(tracker, provider_id) do
      state = maybe_recover_to_degraded(state, now_ms)
      {:ok, to_health_status(state, now_ms)}
    end
  end

  @spec snapshot(t(), integer()) :: %{provider_id() => health_status()}
  def snapshot(%__MODULE__{} = tracker, now_ms) when is_integer(now_ms) do
    Enum.into(tracker.by_provider, %{}, fn {provider_id, state} ->
      {provider_id, to_health_status(maybe_recover_to_degraded(state, now_ms), now_ms)}
    end)
  end

  @spec available_provider_ids(t(), integer()) :: [provider_id()]
  def available_provider_ids(%__MODULE__{} = tracker, now_ms) when is_integer(now_ms) do
    tracker
    |> snapshot(now_ms)
    |> Enum.filter(fn {_provider_id, status} -> not status.excluded? end)
    |> Enum.map(fn {provider_id, _status} -> provider_id end)
  end

  defp fetch_state(%__MODULE__{} = tracker, provider_id) do
    case Map.fetch(tracker.by_provider, provider_id) do
      {:ok, state} ->
        {:ok, state}

      :error ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "unknown routing provider candidate: #{inspect(provider_id)}"
         )}
    end
  end

  defp put_state(%__MODULE__{} = tracker, provider_id, state) do
    %{tracker | by_provider: Map.put(tracker.by_provider, provider_id, state)}
  end

  defp fresh_state do
    %{status: :healthy, failures: 0, last_error: nil, excluded_until_ms: nil}
  end

  defp maybe_recover_to_degraded(
         %{status: :unhealthy, excluded_until_ms: until_ms} = state,
         now_ms
       )
       when is_integer(until_ms) and now_ms >= until_ms do
    %{state | status: :degraded, excluded_until_ms: nil}
  end

  defp maybe_recover_to_degraded(state, _now_ms), do: state

  defp to_health_status(state, now_ms) do
    excluded? =
      case state.excluded_until_ms do
        until_ms when is_integer(until_ms) -> now_ms < until_ms
        _other -> false
      end

    %{
      status: state.status,
      failures: state.failures,
      last_error: state.last_error,
      excluded_until_ms: state.excluded_until_ms,
      excluded?: excluded?
    }
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end

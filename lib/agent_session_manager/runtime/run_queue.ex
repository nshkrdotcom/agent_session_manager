defmodule AgentSessionManager.Runtime.RunQueue do
  @moduledoc """
  Pure FIFO run queue with a configurable maximum size.

  This is a pure data structure (no processes) used by the runtime
  `SessionServer` to implement strict sequential queue draining.
  """

  @enforce_keys [:max_queued_runs, :queue, :size]
  defstruct [:max_queued_runs, :queue, :size]

  @type t :: %__MODULE__{
          max_queued_runs: pos_integer(),
          queue: :queue.queue(String.t()),
          size: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max = Keyword.get(opts, :max_queued_runs, 100)

    %__MODULE__{
      max_queued_runs: max,
      queue: :queue.new(),
      size: 0
    }
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = queue), do: queue.size

  @spec to_list(t()) :: [String.t()]
  def to_list(%__MODULE__{} = queue) do
    :queue.to_list(queue.queue)
  end

  @spec enqueue(t(), String.t()) :: {:ok, t()} | {:error, :queue_full}
  def enqueue(%__MODULE__{} = queue, run_id) when is_binary(run_id) do
    if queue.size >= queue.max_queued_runs do
      {:error, :queue_full}
    else
      new_q = :queue.in(run_id, queue.queue)
      {:ok, %{queue | queue: new_q, size: queue.size + 1}}
    end
  end

  @spec dequeue(t()) :: {:ok, String.t(), t()} | {:empty, t()}
  def dequeue(%__MODULE__{} = queue) do
    case :queue.out(queue.queue) do
      {{:value, run_id}, new_q} ->
        {:ok, run_id, %{queue | queue: new_q, size: queue.size - 1}}

      {:empty, _} ->
        {:empty, queue}
    end
  end

  @spec remove(t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def remove(%__MODULE__{} = queue, run_id) when is_binary(run_id) do
    items = :queue.to_list(queue.queue)

    if run_id in items do
      new_items = Enum.reject(items, &(&1 == run_id))

      new_q =
        new_items
        |> Enum.reduce(:queue.new(), fn id, acc -> :queue.in(id, acc) end)

      {:ok, %{queue | queue: new_q, size: length(new_items)}}
    else
      {:error, :not_found}
    end
  end
end

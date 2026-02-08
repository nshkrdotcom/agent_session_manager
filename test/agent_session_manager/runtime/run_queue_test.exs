defmodule AgentSessionManager.Runtime.RunQueueTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Runtime.RunQueue

  describe "new/1" do
    test "creates an empty FIFO queue" do
      queue = RunQueue.new(max_queued_runs: 3)

      assert RunQueue.size(queue) == 0
      assert RunQueue.to_list(queue) == []
    end
  end

  describe "enqueue/2 and dequeue/1" do
    test "dequeues in FIFO order" do
      queue =
        RunQueue.new(max_queued_runs: 10)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-1")))
        |> elem(1)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-2")))
        |> elem(1)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-3")))
        |> elem(1)

      assert {:ok, "run-1", queue} = RunQueue.dequeue(queue)
      assert {:ok, "run-2", queue} = RunQueue.dequeue(queue)
      assert {:ok, "run-3", queue} = RunQueue.dequeue(queue)
      assert {:empty, queue} = RunQueue.dequeue(queue)
      assert RunQueue.size(queue) == 0
    end

    test "enforces max_queued_runs bound" do
      queue = RunQueue.new(max_queued_runs: 2)

      assert {:ok, queue} = RunQueue.enqueue(queue, "run-1")
      assert {:ok, queue} = RunQueue.enqueue(queue, "run-2")
      assert {:error, :queue_full} = RunQueue.enqueue(queue, "run-3")

      assert RunQueue.to_list(queue) == ["run-1", "run-2"]
    end
  end

  describe "remove/2" do
    test "removes a queued run id" do
      queue =
        RunQueue.new(max_queued_runs: 10)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-1")))
        |> elem(1)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-2")))
        |> elem(1)
        |> then(&({:ok, &1} = RunQueue.enqueue(&1, "run-3")))
        |> elem(1)

      assert {:ok, queue} = RunQueue.remove(queue, "run-2")
      assert RunQueue.to_list(queue) == ["run-1", "run-3"]

      assert {:ok, "run-1", queue} = RunQueue.dequeue(queue)
      assert {:ok, "run-3", queue} = RunQueue.dequeue(queue)
      assert {:empty, _} = RunQueue.dequeue(queue)
    end

    test "returns not_found when run id is absent" do
      queue = RunQueue.new(max_queued_runs: 10)
      assert {:error, :not_found} = RunQueue.remove(queue, "run-404")
    end
  end
end

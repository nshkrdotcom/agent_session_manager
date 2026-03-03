defmodule ASM.Run.ApprovalCoordinator do
  @moduledoc """
  Pure state helper for approval ownership indexing.
  """

  alias ASM.Control

  @type state :: %{optional(String.t()) => pid()}

  @spec new() :: state()
  def new, do: %{}

  @spec register(state(), pid(), Control.ApprovalRequest.t()) :: state()
  def register(index, run_pid, %Control.ApprovalRequest{approval_id: approval_id})
      when is_map(index) and is_pid(run_pid) and is_binary(approval_id) do
    Map.put(index, approval_id, run_pid)
  end

  @spec resolve(state(), String.t()) ::
          {:ok, pid(), state()} | {:error, :unknown_approval, state()}
  def resolve(index, approval_id) when is_map(index) and is_binary(approval_id) do
    case Map.pop(index, approval_id) do
      {nil, remaining} -> {:error, :unknown_approval, remaining}
      {run_pid, remaining} -> {:ok, run_pid, remaining}
    end
  end

  @spec clear(state(), String.t()) :: state()
  def clear(index, approval_id) when is_map(index) and is_binary(approval_id) do
    Map.delete(index, approval_id)
  end
end

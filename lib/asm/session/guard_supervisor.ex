defmodule ASM.Session.GuardSupervisor do
  @moduledoc """
  Dynamic supervisor for `ASM.Session.OwnerGuard` processes.

  Guards are siblings of the session subtrees they watch, never children of
  them, so terminating a subtree never terminates the process performing the
  termination.
  """

  use DynamicSupervisor

  alias ASM.Session.OwnerGuard

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a guard that stops `session_id` when `owner` goes down.
  """
  @spec guard(GenServer.server(), String.t(), pid(), pid()) ::
          DynamicSupervisor.on_start_child()
  def guard(supervisor, session_id, owner, subtree)
      when is_binary(session_id) and is_pid(owner) and is_pid(subtree) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {OwnerGuard,
       [session_id: session_id, owner: owner, subtree: subtree, supervisor: supervisor]}
    )
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end

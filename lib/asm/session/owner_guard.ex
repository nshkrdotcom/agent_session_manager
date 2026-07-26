defmodule ASM.Session.OwnerGuard do
  @moduledoc """
  Binds a session subtree's lifetime to an owner process.

  The provider form of `ASM.query/3` starts a session, runs one prompt, and
  stops the session from the caller's `after` block. An untrappable
  `Process.exit(caller, :kill)` skips that block, and the supervised subtree
  keeps running with its provider process group still attached. This guard
  closes that window: it monitors the owner and terminates the subtree child
  through `ASM.Session.Supervisor.stop_session/2` when the owner goes down.

  Two placement facts matter:

  - stopping a session subtree is `ASM.Session.Server` stopping itself is not
    enough, because `ASM.Session.Subtree` would restart it; the subtree child
    itself has to be terminated
  - the guard therefore lives OUTSIDE the subtree it guards, under
    `ASM.Session.GuardSupervisor`. A guard supervised by the subtree it is
    terminating would be shut down while blocked in that very call

  The guard also monitors the subtree, so an ordinary `ASM.stop_session/1`
  retires the guard instead of leaving it waiting on an owner forever.
  """

  use GenServer, restart: :temporary

  alias ASM.Session

  @type state :: %{
          session_id: String.t(),
          supervisor: GenServer.server(),
          owner_ref: reference(),
          subtree_ref: reference()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner_ref = opts |> Keyword.fetch!(:owner) |> Process.monitor()
    subtree_ref = opts |> Keyword.fetch!(:subtree) |> Process.monitor()

    {:ok,
     %{
       session_id: Keyword.fetch!(opts, :session_id),
       supervisor: Keyword.fetch!(opts, :supervisor),
       owner_ref: owner_ref,
       subtree_ref: subtree_ref
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    _ = Session.Supervisor.stop_session(state.supervisor, state.session_id)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subtree_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end

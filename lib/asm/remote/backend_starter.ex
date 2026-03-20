defmodule ASM.Remote.BackendStarter do
  @moduledoc """
  Remote RPC entrypoint for starting backend sessions.
  """

  alias CliSubprocessCore.Session

  @spec start_core_session(keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def start_core_session(session_opts) when is_list(session_opts) do
    child_spec = %{
      id: {Session, make_ref()},
      start: {Session, :start_link, [session_opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    with {:ok, pid} <- DynamicSupervisor.start_child(ASM.Remote.BackendSupervisor, child_spec) do
      {:ok, pid, Session.info(pid)}
    end
  end
end

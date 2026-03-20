defmodule ASM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Extension supervisors are intentionally started by the host app,
    # so core keeps compile-time/runtime isolation from optional domains.
    children = [
      {Registry, keys: :unique, name: :asm_sessions},
      {Task.Supervisor, name: ASM.TaskSupervisor},
      {ASM.Remote.BackendSupervisor, []},
      {ASM.Session.Supervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ASM.ApplicationSupervisor)
  end
end

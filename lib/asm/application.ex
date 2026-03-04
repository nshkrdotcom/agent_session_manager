defmodule ASM.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: :asm_sessions},
      {ASM.Remote.TransportSupervisor, []},
      {ASM.Session.Supervisor, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ASM.ApplicationSupervisor)
  end
end

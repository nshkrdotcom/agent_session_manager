defmodule AgentSessionManager.StreamSession.Supervisor do
  @moduledoc """
  Convenience supervisor for StreamSession infrastructure.

  Add this to your application supervision tree to enable supervised
  task and adapter lifecycle management for StreamSession:

      children = [
        AgentSessionManager.StreamSession.Supervisor,
        # ... other children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: AgentSessionManager.StreamTaskSupervisor},
      {DynamicSupervisor,
       name: AgentSessionManager.StreamDynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule ASM.Session.Subtree do
  @moduledoc """
  Per-session supervision subtree.

  Child ordering is intentional and uses `:rest_for_one`:

  1. run supervisor
  2. session aggregate server
  """

  use Supervisor

  @registry :asm_sessions

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = Keyword.get(opts, :name, via_name(session_id, :subtree))

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @spec via_name(String.t(), atom()) :: {:via, Registry, {atom(), {String.t(), atom()}}}
  def via_name(session_id, role) when is_binary(session_id) and is_atom(role) do
    {:via, Registry, {@registry, {session_id, role}}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    provider = Keyword.get(opts, :provider, :claude)
    session_options = Keyword.get(opts, :options, [])

    children = [
      {ASM.Run.Supervisor, [session_id: session_id, name: via_name(session_id, :run_sup)]},
      {ASM.Session.Server,
       [
         session_id: session_id,
         provider: provider,
         options: session_options,
         name: via_name(session_id, :server)
       ]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

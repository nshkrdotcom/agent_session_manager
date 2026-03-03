defmodule ASM.Session.Supervisor do
  @moduledoc """
  Root dynamic supervisor for session subtrees.
  """

  use DynamicSupervisor

  @registry :asm_sessions

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts), do: start_session(__MODULE__, opts)

  @spec start_session(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor, opts) when is_list(opts) do
    session_id = Keyword.get_lazy(opts, :session_id, &ASM.Event.generate_id/0)
    provider = Keyword.get(opts, :provider, :claude)

    session_options =
      opts
      |> Keyword.drop([:session_id, :provider, :name, :options])
      |> Keyword.merge(Keyword.get(opts, :options, []))

    subtree_opts =
      opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:options, session_options)

    DynamicSupervisor.start_child(supervisor, {ASM.Session.Subtree, subtree_opts})
  end

  @spec stop_session(String.t() | pid()) :: :ok | {:error, :not_found}
  def stop_session(session_or_pid), do: stop_session(__MODULE__, session_or_pid)

  @spec stop_session(GenServer.server(), String.t() | pid()) :: :ok | {:error, :not_found}
  def stop_session(supervisor, pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  def stop_session(supervisor, session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, {session_id, :subtree}) do
      [{pid, _}] -> stop_session(supervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @spec list_sessions() :: [String.t()]
  def list_sessions do
    Registry.select(@registry, [{{{:"$1", :subtree}, :_, :_}, [], [:"$1"]}])
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

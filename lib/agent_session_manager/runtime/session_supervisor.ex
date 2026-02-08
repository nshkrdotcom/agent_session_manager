defmodule AgentSessionManager.Runtime.SessionSupervisor do
  @moduledoc """
  Supervisor for the session runtime.

  Starts:

  - a `Registry` for per-session process names
  - a `DynamicSupervisor` for `SessionServer` processes

  This module is optional and intended for applications that want a
  ready-made runtime process tree.
  """

  use Supervisor

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Runtime.{SessionRegistry, SessionServer}

  @type start_session_opts :: [
          {:session_id, String.t()}
          | {:session_opts, map()}
          | {:store, any()}
          | {:adapter, any()}
          | {:max_concurrent_runs, pos_integer()}
          | {:max_queued_runs, pos_integer()}
          | {:limiter, GenServer.server()}
          | {:default_execute_opts, keyword()}
        ]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, {name, opts}, name: name)
  end

  @spec start_session(Supervisor.supervisor(), start_session_opts()) ::
          {:ok, pid()} | {:error, Error.t()}
  def start_session(supervisor, opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)

    {registry_name, sessions_sup_name} = child_names(supervisor)

    name = if is_binary(session_id), do: SessionRegistry.via_tuple(registry_name, session_id)

    child_opts =
      opts
      |> Keyword.put_new(:max_concurrent_runs, 1)
      |> maybe_put(:name, name)

    spec = {SessionServer, child_opts}

    case DynamicSupervisor.start_child(sessions_sup_name, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:internal_error, "Failed to start session: #{inspect(reason)}")}
    end
  end

  @spec whereis(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | :error
  def whereis(supervisor, session_id) when is_binary(session_id) do
    {registry_name, _sessions_sup_name} = child_names(supervisor)
    SessionRegistry.lookup(registry_name, session_id)
  end

  @impl Supervisor
  def init({name, opts}) do
    registry_name = Keyword.get(opts, :registry_name, default_registry_name(name))

    sessions_sup_name =
      Keyword.get(opts, :sessions_supervisor_name, default_sessions_sup_name(name))

    children = [
      {Registry, keys: :unique, name: registry_name},
      {DynamicSupervisor, strategy: :one_for_one, name: sessions_sup_name}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp child_names(supervisor) when is_atom(supervisor) do
    {default_registry_name(supervisor), default_sessions_sup_name(supervisor)}
  end

  defp child_names(supervisor) when is_pid(supervisor) do
    names =
      Supervisor.which_children(supervisor)
      |> Enum.flat_map(fn
        {Registry, pid, :worker, _} -> [{:registry, pid}]
        {DynamicSupervisor, pid, :supervisor, _} -> [{:sessions_sup, pid}]
        _ -> []
      end)
      |> Map.new()

    registry_pid = Map.fetch!(names, :registry)

    registry_ref =
      case Process.info(registry_pid, :registered_name) do
        {:registered_name, name} when is_atom(name) -> name
        _ -> registry_pid
      end

    {registry_ref, Map.fetch!(names, :sessions_sup)}
  end

  defp default_registry_name(name) when is_atom(name), do: :"#{name}.SessionRegistry"
  defp default_sessions_sup_name(name) when is_atom(name), do: :"#{name}.Sessions"

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

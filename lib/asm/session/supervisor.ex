defmodule ASM.Session.Supervisor do
  @moduledoc """
  Root dynamic supervisor for session subtrees.
  """

  use DynamicSupervisor

  alias ASM.{Error, RuntimeAuth}
  alias ASM.Execution.Config
  alias ASM.Provider
  alias ASM.Session.GuardSupervisor
  alias ASM.Session.Server

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
      |> Keyword.drop([:session_id, :provider, :name, :options, :owner])
      |> Keyword.merge(Keyword.get(opts, :options, []))

    with {:ok, provider_config} <- Provider.resolve(provider),
         {:ok, session_options} <-
           normalize_session_options(provider_config.name, session_options),
         {:ok, runtime_auth} <-
           RuntimeAuth.new(session_id, provider_config.name, session_options),
         {:ok, session_options} <-
           RuntimeAuth.prepare_session_options(runtime_auth, session_options) do
      subtree_opts =
        opts
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:provider, provider_config.name)
        |> Keyword.put(:options, session_options)
        |> Keyword.put(:runtime_auth, runtime_auth)

      supervisor
      |> DynamicSupervisor.start_child({ASM.Session.Subtree, subtree_opts})
      |> maybe_scope_to_owner(supervisor, session_id, Keyword.get(opts, :owner))
    end
  end

  # An owned session is bound to the owner's lifetime: when the owner goes
  # down for any reason, including an untrappable kill, the guard terminates
  # the subtree child and with it the provider process group. Failing to start
  # the guard fails the session, so an owned session is never silently
  # downgraded to an unowned one.
  defp maybe_scope_to_owner(result, _supervisor, _session_id, nil), do: result

  defp maybe_scope_to_owner({:ok, subtree_pid} = result, supervisor, session_id, owner)
       when is_pid(owner) do
    case GuardSupervisor.guard(supervisor, session_id, owner, subtree_pid) do
      {:ok, _guard_pid} ->
        result

      {:error, reason} ->
        _ = stop_session(supervisor, subtree_pid)

        {:error,
         Error.new(
           :runtime,
           :runtime,
           "unable to scope session #{session_id} to its owner: #{inspect(reason)}",
           cause: reason
         )}
    end
  end

  defp maybe_scope_to_owner(result, _supervisor, _session_id, _owner), do: result

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

  @doc "Revokes a managed session by opaque session id after exact lease-scope validation."
  @spec revoke_managed_session(String.t(), map() | keyword()) ::
          :ok | {:error, Error.t() | :not_found}
  def revoke_managed_session(session_id, revocation) when is_binary(session_id) do
    with {:ok, server} <- lookup_session_server(session_id) do
      Server.revoke_materialization(server, revocation)
    end
  end

  @doc "Closes a managed session's materialization when its owning scope is cleaned up."
  @spec cleanup_managed_session(String.t(), atom()) ::
          :ok | {:error, Error.t() | :not_found}
  def cleanup_managed_session(session_id, reason \\ :scope_closed)
      when is_binary(session_id) and is_atom(reason) do
    with {:ok, server} <- lookup_session_server(session_id) do
      Server.cleanup_materialization(server, reason)
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

  defp normalize_session_options(provider, session_options) when is_list(session_options) do
    case Config.resolve(session_options, [], provider: provider) do
      {:ok, %Config{} = execution_config} ->
        {:ok, merge_execution_config(session_options, execution_config)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp merge_execution_config(session_options, %Config{} = execution_config) do
    execution_environment = Config.to_execution_environment(execution_config)

    session_options
    |> Keyword.put(:execution_mode, execution_config.execution_mode)
    |> Keyword.put(:transport_call_timeout_ms, execution_config.transport_call_timeout_ms)
    |> Keyword.put(:execution_surface, Config.to_execution_surface(execution_config))
    |> Keyword.put(:execution_environment, execution_environment)
    |> Keyword.put(:allowed_tools, execution_environment.allowed_tools)
    |> maybe_put(:workspace_root, execution_environment.workspace_root)
    |> maybe_put(:approval_posture, execution_environment.approval_posture)
    |> maybe_put(:permission_mode, execution_environment.permission_mode)
    |> maybe_put(:provider_permission_mode, execution_config.provider_permission_mode)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp lookup_session_server(session_id) do
    case Registry.lookup(@registry, {session_id, :server}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end

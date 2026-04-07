defmodule ASM.Session.Supervisor do
  @moduledoc """
  Root dynamic supervisor for session subtrees.
  """

  use DynamicSupervisor

  alias ASM.Execution.Config

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

    with {:ok, session_options} <- normalize_session_options(provider, session_options) do
      subtree_opts =
        opts
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:provider, provider)
        |> Keyword.put(:options, session_options)

      DynamicSupervisor.start_child(supervisor, {ASM.Session.Subtree, subtree_opts})
    end
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
end

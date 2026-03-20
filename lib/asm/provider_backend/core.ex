defmodule ASM.ProviderBackend.Core do
  @moduledoc """
  Backend that runs the shared CLI runtime from `cli_subprocess_core`.
  """

  @behaviour ASM.ProviderBackend

  alias ASM.{Error, Execution, Provider}
  alias ASM.Remote.NodeConnector
  alias CliSubprocessCore.Session

  @session_event_tag :cli_subprocess_core_session

  @impl true
  def start_run(%{provider: %Provider{} = provider} = config) do
    with {:ok, execution_config} <- fetch_execution_config(config),
         session_opts <- build_session_opts(provider, config),
         {:ok, pid, info} <- do_start_run(execution_config, session_opts) do
      {:ok, pid, %{lane: :core, provider: provider.name, session: info}}
    end
  end

  @impl true
  def send_input(session, input, opts \\ []) when is_pid(session) do
    Session.send_input(session, input, opts)
  end

  @impl true
  def end_input(session) when is_pid(session), do: Session.end_input(session)

  @impl true
  def interrupt(session) when is_pid(session), do: Session.interrupt(session)

  @impl true
  def close(session) when is_pid(session), do: Session.close(session)

  @impl true
  def subscribe(session, pid, ref) when is_pid(session) and is_pid(pid) and is_reference(ref) do
    Session.subscribe(session, pid, ref)
  end

  @impl true
  def info(session) when is_pid(session), do: Session.info(session)

  defp fetch_execution_config(%{execution_config: %Execution.Config{} = config}),
    do: {:ok, config}

  defp fetch_execution_config(_config) do
    {:error, Error.new(:config_invalid, :config, "missing execution config for core backend")}
  end

  defp do_start_run(%Execution.Config{execution_mode: :local}, session_opts) do
    Session.start_session(session_opts)
  end

  defp do_start_run(
         %Execution.Config{execution_mode: :remote_node, remote: remote_cfg},
         session_opts
       )
       when is_map(remote_cfg) do
    with :ok <- connect_remote(remote_cfg),
         :ok <- preflight_remote(remote_cfg),
         :ok <- maybe_bootstrap_remote(remote_cfg),
         {:ok, pid, info} <- remote_start(remote_cfg, session_opts) do
      {:ok, pid, info}
    end
  end

  defp build_session_opts(provider, config) do
    metadata =
      Map.merge(
        %{lane: :core, asm_provider: provider.name},
        Map.get(config, :metadata, %{})
      )

    subscriber =
      case {Map.get(config, :subscriber_pid), Map.get(config, :subscription_ref)} do
        {pid, ref} when is_pid(pid) and is_reference(ref) -> {pid, ref}
        _ -> nil
      end

    provider_opts =
      config
      |> Map.get(:provider_opts, [])
      |> Keyword.put(:prompt, Map.fetch!(config, :prompt))
      |> maybe_put_cli_path()

    [
      provider: provider.name,
      profile: provider.core_profile,
      subscriber: subscriber,
      metadata: metadata,
      session_event_tag: @session_event_tag
    ] ++ provider_opts
  end

  defp maybe_put_cli_path(provider_opts) do
    case Keyword.get(provider_opts, :cli_path) do
      path when is_binary(path) and path != "" ->
        provider_opts
        |> Keyword.put(:command, path)
        |> Keyword.delete(:cli_path)

      _ ->
        provider_opts
    end
  end

  defp connect_remote(remote_cfg) do
    case NodeConnector.ensure_connected(remote_cfg) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, remote_error("remote connect failed: #{inspect(reason)}", reason)}
    end
  end

  defp preflight_remote(remote_cfg) do
    case NodeConnector.preflight(remote_cfg) do
      :ok ->
        :ok

      {:error, :remote_not_ready} when remote_cfg.remote_bootstrap_mode == :ensure_started ->
        :ok

      {:error, reason} ->
        {:error, remote_error("remote preflight failed: #{inspect(reason)}", reason)}
    end
  end

  defp maybe_bootstrap_remote(%{remote_bootstrap_mode: :ensure_started} = remote_cfg) do
    case :rpc.call(
           remote_cfg.remote_node,
           Application,
           :ensure_all_started,
           [:agent_session_manager],
           remote_cfg.remote_rpc_timeout_ms
         ) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        {:error, remote_error("remote bootstrap failed: #{inspect(reason)}", reason)}

      {:badrpc, reason} ->
        {:error, remote_error("remote bootstrap failed: #{inspect(reason)}", reason)}

      _other ->
        :ok
    end
  end

  defp maybe_bootstrap_remote(_remote_cfg), do: :ok

  defp remote_start(remote_cfg, session_opts) do
    case :rpc.call(
           remote_cfg.remote_node,
           ASM.Remote.BackendStarter,
           :start_core_session,
           [session_opts],
           remote_cfg.remote_rpc_timeout_ms
         ) do
      {:ok, pid, info} when is_pid(pid) ->
        {:ok, pid, info}

      {:error, reason} ->
        {:error, remote_error("remote backend start failed: #{inspect(reason)}", reason)}

      {:badrpc, reason} ->
        {:error, remote_error("remote backend start failed: #{inspect(reason)}", reason)}

      other ->
        {:error, remote_error("remote backend start failed: #{inspect(other)}", other)}
    end
  end

  defp remote_error(message, cause) do
    Error.new(:connection_failed, :runtime, message, cause: cause)
  end
end

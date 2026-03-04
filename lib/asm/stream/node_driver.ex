defmodule ASM.Stream.NodeDriver do
  @moduledoc """
  Remote-node stream driver that starts transports over Erlang distribution.
  """

  alias ASM.{Error, Options, Provider, Run, Telemetry, Transport}
  alias ASM.Execution.Config
  alias ASM.Remote.NodeConnector

  @spec start(map()) :: {:ok, pid()} | {:error, Error.t()}
  def start(context) when is_map(context) do
    start(context, [])
  end

  @spec start(map(), keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def start(context, overrides) when is_map(context) and is_list(overrides) do
    with {:ok, execution_cfg} <- resolve_execution_config(context),
         :ok <- ensure_remote_mode(execution_cfg),
         {:ok, provider} <- Provider.resolve(context.provider),
         {:ok, validated_opts} <- validate_local_provider_opts(provider, context, execution_cfg),
         :ok <- connect_remote(context, execution_cfg, overrides),
         :ok <- preflight_remote(context, execution_cfg, overrides),
         {:ok, transport_pid} <-
           rpc_start_transport(context, execution_cfg, validated_opts, overrides),
         :ok <- attach_transport(context, transport_pid, execution_cfg, overrides) do
      {:ok, transport_pid}
    else
      {:error, %Error{} = error} ->
        emit_remote_error(context, execution_cfg_or_nil(context), error)
        {:error, error}
    end
  rescue
    error ->
      wrapped = runtime_error(Exception.message(error), error)
      emit_remote_error(context, execution_cfg_or_nil(context), wrapped)
      {:error, wrapped}
  end

  defp resolve_execution_config(%{execution_config: %Config{} = cfg}), do: {:ok, cfg}

  defp resolve_execution_config(%{driver_opts: driver_opts}) when is_list(driver_opts) do
    Config.resolve([], execution_mode: :remote_node, driver_opts: driver_opts)
  end

  defp resolve_execution_config(_context) do
    {:error, Error.new(:config_invalid, :config, "node driver requires execution config")}
  end

  defp ensure_remote_mode(%Config{execution_mode: :remote_node}), do: :ok

  defp ensure_remote_mode(%Config{execution_mode: mode}) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "node driver requires :remote_node execution mode, got: #{inspect(mode)}"
     )}
  end

  defp validate_local_provider_opts(provider, context, %Config{remote: remote_cfg}) do
    provider_opts =
      context.provider_opts
      |> normalize_keyword()
      |> maybe_apply_remote_cwd(remote_cfg.remote_cwd)

    options = Keyword.put(provider_opts, :provider, provider.name)
    Options.validate(options, provider.options_schema)
  end

  defp connect_remote(context, %Config{remote: remote_cfg}, overrides) do
    fun = Keyword.get(overrides, :ensure_connected_fun, &NodeConnector.ensure_connected/1)
    metadata = remote_metadata(context, remote_cfg)

    started_at = System.monotonic_time(:millisecond)
    Telemetry.remote_connect_start(metadata)

    case fun.(remote_cfg) do
      :ok ->
        Telemetry.remote_connect_stop(metadata, duration_ms(started_at))
        :ok

      {:error, reason} ->
        Telemetry.remote_connect_stop(
          Map.put(metadata, :error_kind, reason),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote connect failed: #{inspect(reason)}", reason)}
    end
  end

  defp preflight_remote(context, %Config{remote: remote_cfg} = execution_cfg, overrides) do
    preflight_fun = Keyword.get(overrides, :preflight_fun, &NodeConnector.preflight/1)
    rpc_fun = Keyword.get(overrides, :rpc_fun, &:rpc.call/5)
    metadata = remote_metadata(context, remote_cfg)

    started_at = System.monotonic_time(:millisecond)
    Telemetry.remote_preflight_start(metadata)

    case preflight_fun.(remote_cfg) do
      :ok ->
        Telemetry.remote_preflight_stop(metadata, duration_ms(started_at))
        :ok

      {:error, :remote_not_ready}
      when remote_cfg.remote_bootstrap_mode == :ensure_started ->
        with :ok <- bootstrap_remote_app(remote_cfg, rpc_fun),
             :ok <- preflight_fun.(remote_cfg) do
          Telemetry.remote_preflight_stop(metadata, duration_ms(started_at))
          :ok
        else
          {:error, reason} ->
            Telemetry.remote_preflight_stop(
              Map.put(metadata, :error_kind, reason),
              duration_ms(started_at)
            )

            {:error,
             runtime_error("remote preflight failed after bootstrap: #{inspect(reason)}", reason)}
        end

      {:error, reason} ->
        _ = execution_cfg

        Telemetry.remote_preflight_stop(
          Map.put(metadata, :error_kind, reason),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote preflight failed: #{inspect(reason)}", reason)}
    end
  end

  defp bootstrap_remote_app(remote_cfg, rpc_fun) do
    case rpc_fun.(
           remote_cfg.remote_node,
           Application,
           :ensure_all_started,
           [:agent_session_manager],
           remote_cfg.remote_rpc_timeout_ms
         ) do
      {:ok, _started} ->
        :ok

      {:badrpc, :timeout} ->
        {:error, :remote_rpc_timeout}

      {:badrpc, reason} ->
        {:error, {:remote_bootstrap_failed, reason}}

      {:error, reason} ->
        {:error, {:remote_bootstrap_failed, reason}}

      other ->
        {:error, {:remote_bootstrap_failed, other}}
    end
  end

  defp rpc_start_transport(context, %Config{remote: remote_cfg}, validated_opts, overrides) do
    rpc_fun = Keyword.get(overrides, :rpc_fun, &:rpc.call/5)
    metadata = remote_metadata(context, remote_cfg)

    starter_ctx = %{
      provider: context.provider,
      prompt: context.prompt,
      provider_opts: Keyword.delete(validated_opts, :provider),
      remote_cwd: remote_cfg.remote_cwd,
      remote_boot_lease_timeout_ms: remote_cfg.remote_boot_lease_timeout_ms
    }

    started_at = System.monotonic_time(:millisecond)
    Telemetry.remote_rpc_start_transport_start(metadata)

    case rpc_fun.(
           remote_cfg.remote_node,
           ASM.Remote.TransportStarter,
           :start_transport,
           [starter_ctx],
           remote_cfg.remote_rpc_timeout_ms
         ) do
      {:ok, transport_pid} when is_pid(transport_pid) ->
        Telemetry.remote_rpc_start_transport_stop(metadata, duration_ms(started_at))
        {:ok, transport_pid}

      {:error, :cli_not_found} ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :cli_not_found),
          duration_ms(started_at)
        )

        {:error, Error.new(:cli_not_found, :provider, "remote cli not found")}

      {:error, {:workspace_failed, reason}} ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :workspace_failed),
          duration_ms(started_at)
        )

        {:error,
         runtime_error("remote workspace failed: #{inspect(reason)}", {:workspace_failed, reason})}

      {:error, {:transport_start_failed, reason}} ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :transport_start_failed),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote transport start failed: #{inspect(reason)}", reason)}

      {:badrpc, :timeout} ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :remote_rpc_timeout),
          duration_ms(started_at)
        )

        {:error,
         runtime_error("remote rpc timeout while starting transport", :remote_rpc_timeout)}

      {:badrpc, reason} ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :remote_rpc_failed),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote rpc failed: #{inspect(reason)}", reason)}

      other ->
        Telemetry.remote_rpc_start_transport_stop(
          Map.put(metadata, :error_kind, :transport_start_failed),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote transport start failed: #{inspect(other)}", other)}
    end
  end

  defp attach_transport(context, transport_pid, %Config{remote: remote_cfg}, overrides) do
    attach_fun = Keyword.get(overrides, :attach_fun, &Run.Server.attach_transport/2)
    close_fun = Keyword.get(overrides, :close_transport_fun, &Transport.close/1)
    metadata = remote_metadata(context, remote_cfg)

    started_at = System.monotonic_time(:millisecond)
    Telemetry.remote_attach_start(metadata)

    attach_result =
      try do
        attach_fun.(context.run_pid, transport_pid)
      catch
        :exit, reason -> {:error, {:attach_exit, reason}}
      end

    case attach_result do
      :ok ->
        Telemetry.remote_attach_stop(metadata, duration_ms(started_at))
        :ok

      {:error, %Error{} = error} ->
        _ = best_effort_close_transport(close_fun, transport_pid)

        Telemetry.remote_attach_stop(
          Map.put(metadata, :error_kind, :attach_failed),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote attach failed: #{error.message}", error)}

      {:error, reason} ->
        _ = best_effort_close_transport(close_fun, transport_pid)

        Telemetry.remote_attach_stop(
          Map.put(metadata, :error_kind, :attach_failed),
          duration_ms(started_at)
        )

        {:error, runtime_error("remote attach failed: #{inspect(reason)}", reason)}
    end
  end

  defp best_effort_close_transport(close_fun, transport_pid) do
    _ = close_fun.(transport_pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp remote_metadata(context, remote_cfg) do
    %{
      session_id: context.session_id,
      run_id: context.run_id,
      provider: context.provider,
      remote_node: remote_cfg.remote_node,
      execution_mode: :remote_node
    }
  end

  defp duration_ms(started_at), do: max(System.monotonic_time(:millisecond) - started_at, 0)

  defp execution_cfg_or_nil(%{execution_config: %Config{} = cfg}), do: cfg
  defp execution_cfg_or_nil(_), do: nil

  defp emit_remote_error(_context, nil, _error), do: :ok

  defp emit_remote_error(context, %Config{remote: remote_cfg}, %Error{} = error) do
    Telemetry.remote_error(%{
      session_id: context.session_id,
      run_id: context.run_id,
      provider: context.provider,
      remote_node: remote_cfg.remote_node,
      execution_mode: :remote_node,
      error_kind: error.kind
    })
  end

  defp maybe_apply_remote_cwd(opts, nil), do: opts
  defp maybe_apply_remote_cwd(opts, remote_cwd), do: Keyword.put(opts, :cwd, remote_cwd)

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(_value), do: []

  defp runtime_error(message, cause) do
    Error.new(:runtime, :runtime, message, cause: cause)
  end
end

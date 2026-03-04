defmodule ASM.Remote.TransportStarter do
  @moduledoc """
  Remote RPC entrypoint for starting provider transports.
  """

  alias ASM.{Error, Options, Provider}
  alias ASM.Provider.Resolver
  alias ASM.Transport.PTY

  @spec start_transport(map()) ::
          {:ok, pid()}
          | {:error, :cli_not_found}
          | {:error, {:workspace_failed, term()}}
          | {:error, {:transport_start_failed, term()}}
  def start_transport(%{} = ctx) do
    with {:ok, provider} <- Provider.resolve(Map.fetch!(ctx, :provider)),
         {:ok, validated_opts} <-
           validate_provider_opts(provider, Map.get(ctx, :provider_opts, [])),
         {:ok, remote_opts} <- apply_remote_cwd(validated_opts, Map.get(ctx, :remote_cwd)),
         :ok <- ensure_workspace(Keyword.get(remote_opts, :cwd)),
         {:ok, command_spec, command_args} <-
           provider.command_builder.build(Map.fetch!(ctx, :prompt), remote_opts),
         {:ok, transport_pid} <-
           start_transport_child(
             provider,
             command_spec,
             command_args,
             remote_opts,
             Map.get(ctx, :remote_boot_lease_timeout_ms, 10_000)
           ) do
      {:ok, transport_pid}
    else
      {:error, %Error{kind: :cli_not_found}} ->
        {:error, :cli_not_found}

      {:error, %Error{} = error} ->
        {:error, {:transport_start_failed, error}}

      {:error, {:workspace_failed, _reason} = workspace_error} ->
        {:error, workspace_error}

      {:error, reason} ->
        {:error, {:transport_start_failed, reason}}
    end
  end

  defp validate_provider_opts(provider, provider_opts) do
    options = Keyword.put(provider_opts, :provider, provider.name)

    case Options.validate(options, provider.options_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp apply_remote_cwd(opts, nil), do: {:ok, opts}

  defp apply_remote_cwd(opts, remote_cwd) when is_binary(remote_cwd),
    do: {:ok, Keyword.put(opts, :cwd, remote_cwd)}

  defp apply_remote_cwd(_opts, value),
    do: {:error, {:transport_start_failed, {:invalid_remote_cwd, value}}}

  defp ensure_workspace(nil), do: :ok

  defp ensure_workspace(path) when is_binary(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_failed, reason}}
    end
  end

  defp start_transport_child(
         provider,
         command_spec,
         command_args,
         validated_opts,
         startup_lease_timeout_ms
       ) do
    args = Resolver.command_args(command_spec, command_args)

    {program, args} = PTY.maybe_wrap(provider, command_spec.program, args)

    transport_opts = [
      program: program,
      args: args,
      cwd: Keyword.get(validated_opts, :cwd),
      env: Keyword.get(validated_opts, :env, %{}),
      queue_limit: Keyword.get(validated_opts, :queue_limit, 1_000),
      overflow_policy: Keyword.get(validated_opts, :overflow_policy, :fail_run),
      transport_timeout_ms: Keyword.get(validated_opts, :transport_timeout_ms, 60_000),
      headless_timeout_ms: Keyword.get(validated_opts, :transport_headless_timeout_ms, 5_000),
      max_stdout_buffer_bytes: Keyword.get(validated_opts, :max_stdout_buffer_bytes, 1_048_576),
      max_stderr_buffer_bytes: Keyword.get(validated_opts, :max_stderr_buffer_bytes, 65_536),
      startup_lease_timeout_ms: startup_lease_timeout_ms
    ]

    child_spec = %{
      id: {ASM.Transport.Port, make_ref()},
      start: {ASM.Transport.Port, :start_link, [transport_opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    case DynamicSupervisor.start_child(ASM.Remote.TransportSupervisor, child_spec) do
      {:ok, transport_pid} -> {:ok, transport_pid}
      {:error, reason} -> {:error, {:transport_start_failed, reason}}
    end
  end
end

defmodule ASM.Stream.CLIDriver do
  @moduledoc """
  CLI-backed stream driver that starts a supervised transport and binds it to the run worker.
  """

  alias ASM.{Error, Options, Provider, Run}
  alias ASM.Provider.Resolver
  alias ASM.Transport.PTY

  @spec start(map()) :: {:ok, pid()} | {:error, Error.t() | term()}
  def start(%{} = context) do
    with {:ok, provider} <- Provider.resolve(context.provider),
         {:ok, validated_opts} <- validate_options(provider, context.provider_opts),
         {:ok, command_spec, command_args} <-
           provider.command_builder.build(context.prompt, validated_opts),
         {:ok, transport_sup} <- lookup_transport_supervisor(context.session_id),
         {:ok, transport_pid} <-
           start_transport_child(
             transport_sup,
             provider,
             command_spec,
             command_args,
             validated_opts
           ),
         :ok <- Run.Server.attach_transport(context.run_pid, transport_pid) do
      {:ok, transport_pid}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:runtime, :runtime, "cli driver failed: #{inspect(reason)}", cause: reason)}
    end
  rescue
    error ->
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error)}
  end

  defp validate_options(provider, provider_opts) when is_list(provider_opts) do
    options = Keyword.put(provider_opts, :provider, provider.name)
    Options.validate(options, provider.options_schema)
  end

  defp lookup_transport_supervisor(session_id) when is_binary(session_id) do
    case Registry.lookup(:asm_sessions, {session_id, :transport_sup}) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        {:error, Error.new(:runtime, :runtime, "transport supervisor not found")}
    end
  end

  defp start_transport_child(transport_sup, provider, command_spec, command_args, validated_opts) do
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
      max_stderr_buffer_bytes: Keyword.get(validated_opts, :max_stderr_buffer_bytes, 65_536)
    ]

    restart = provider.profile.transport_restart

    child_spec = %{
      id: {ASM.Transport.Port, make_ref()},
      start: {ASM.Transport.Port, :start_link, [transport_opts]},
      restart: restart,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(transport_sup, child_spec)
  end
end

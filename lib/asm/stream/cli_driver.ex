defmodule ASM.Stream.CLIDriver do
  @moduledoc """
  CLI-backed stream driver that starts a supervised transport and binds it to the run worker.
  """

  alias ASM.{Error, Options, Provider, Run}
  alias ASM.Provider.Resolver

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

    {program, args} =
      maybe_wrap_with_pty(
        provider,
        command_spec.program,
        args
      )

    transport_opts = [
      program: program,
      args: args,
      cwd: Keyword.get(validated_opts, :cwd),
      env: Keyword.get(validated_opts, :env, %{}),
      queue_limit: Keyword.get(validated_opts, :queue_limit, 1_000),
      overflow_policy: Keyword.get(validated_opts, :overflow_policy, :fail_run),
      transport_timeout_ms: Keyword.get(validated_opts, :transport_timeout_ms, 60_000)
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

  # Claude CLI expects a TTY when executed from BEAM ports for some environments.
  # We run it through `script` to provide a PTY while preserving streamed stdout.
  defp maybe_wrap_with_pty(%Provider{name: :claude}, program, args) do
    case System.find_executable("script") do
      nil ->
        {program, args}

      script_program ->
        command = shell_join([program | args])
        {script_program, ["-q", "-c", command, "/dev/null"]}
    end
  end

  defp maybe_wrap_with_pty(_provider, program, args), do: {program, args}

  defp shell_join(argv) when is_list(argv) do
    Enum.map_join(argv, " ", &shell_escape/1)
  end

  defp shell_escape(value) do
    value
    |> to_string()
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end

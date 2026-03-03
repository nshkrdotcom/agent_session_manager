defmodule ASM.Stream.CLIDriver do
  @moduledoc """
  CLI-backed stream driver that executes provider commands and ingests parsed events.
  """

  alias ASM.{Control, Error, Event, Message, Options, Protocol, Provider, Run}
  alias ASM.Provider.Resolver

  @spec start(map()) :: {:ok, pid()} | {:error, Error.t() | term()}
  def start(%{} = context) do
    {:ok, spawn(fn -> run(context) end)}
  end

  defp run(context) do
    with {:ok, provider} <- Provider.resolve(context.provider),
         {:ok, validated_opts} <- validate_options(provider, context.provider_opts),
         {:ok, command_spec, command_args} <-
           provider.command_builder.build(context.prompt, validated_opts) do
      args = Resolver.command_args(command_spec, command_args)

      command_spec.program
      |> open_port(args, validated_opts)
      |> stream_port(context, provider)
    else
      {:error, %Error{} = error} ->
        emit_error(context, error)

      {:error, reason} ->
        emit_error(
          context,
          Error.new(:runtime, :runtime, "cli driver failed: #{inspect(reason)}", cause: reason)
        )
    end
  rescue
    error ->
      emit_error(
        context,
        Error.new(:runtime, :runtime, Exception.message(error), cause: error)
      )
  end

  defp validate_options(provider, provider_opts) when is_list(provider_opts) do
    options = Keyword.put(provider_opts, :provider, provider.name)
    Options.validate(options, provider.options_schema)
  end

  defp open_port(program, args, validated_opts) do
    opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &to_charlist/1)
      ]
      |> maybe_put_env(Keyword.get(validated_opts, :env, %{}))
      |> maybe_put_cwd(Keyword.get(validated_opts, :cwd))

    Port.open({:spawn_executable, to_charlist(program)}, opts)
  end

  defp stream_port(port, context, provider) do
    timeout_ms =
      context.provider_opts
      |> Keyword.get(:transport_timeout_ms, 60_000)
      |> normalize_timeout()

    loop(port, context, provider, "", timeout_ms, false)
  end

  defp loop(port, context, provider, buffer, timeout_ms, saw_terminal?) do
    receive do
      {^port, {:data, chunk}} ->
        {lines, remainder} = Protocol.JSONL.extract_lines(buffer <> chunk)

        next_terminal =
          Enum.reduce(lines, saw_terminal?, fn line, terminal? ->
            terminal? or handle_line(line, context, provider)
          end)

        loop(port, context, provider, remainder, timeout_ms, next_terminal)

      {^port, {:exit_status, status}} ->
        emit_exit(context, status, saw_terminal?)

      {^port, :closed} ->
        emit_exit(context, 0, saw_terminal?)
    after
      timeout_ms ->
        Port.close(port)

        emit_error(
          context,
          Error.new(:timeout, :transport, "provider command timed out after #{timeout_ms}ms")
        )
    end
  end

  defp handle_line("", _context, _provider), do: false

  defp handle_line(line, context, provider) do
    with {:ok, decoded} <- Protocol.JSONL.decode_line(line),
         {:ok, {kind, payload}} <- provider.parser.parse(decoded) do
      safe_ingest(context.run_pid, event(context, kind, payload))
      terminal_event?(kind)
    else
      {:error, %Error{} = error} ->
        emit_error(context, error)
        false

      {:error, reason} ->
        emit_error(
          context,
          Error.new(:parse_error, :parser, "failed to parse provider line: #{inspect(reason)}",
            cause: reason
          )
        )

        false
    end
  end

  defp emit_exit(_context, 0, true), do: :ok

  defp emit_exit(context, 0, false) do
    safe_ingest(
      context.run_pid,
      event(
        context,
        :run_completed,
        %Control.RunLifecycle{
          status: :completed,
          summary: %{source: :cli_exit}
        }
      )
    )
  end

  defp emit_exit(context, status, _terminal?) do
    emit_error(
      context,
      Error.new(
        :transport_error,
        :transport,
        "provider process exited with status #{status}",
        exit_code: status
      )
    )
  end

  defp emit_error(context, %Error{} = error) do
    safe_ingest(
      context.run_pid,
      event(
        context,
        :error,
        %Message.Error{
          severity: :error,
          message: error.message,
          kind: error.kind
        }
      )
    )
  end

  defp safe_ingest(run_pid, %Event{} = event) when is_pid(run_pid) do
    if Process.alive?(run_pid) do
      Run.Server.ingest_event(run_pid, event)
    end
  end

  defp event(context, kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: context.run_id,
      session_id: context.session_id,
      provider: context.provider,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  defp maybe_put_env(opts, env) when is_map(env) and map_size(env) > 0 do
    env_pairs =
      Enum.map(env, fn {key, value} ->
        {to_charlist(to_string(key)), to_charlist(to_string(value))}
      end)

    [{:env, env_pairs} | opts]
  end

  defp maybe_put_env(opts, _env), do: opts

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd) and cwd != "" do
    [{:cd, to_charlist(cwd)} | opts]
  end

  defp maybe_put_cwd(opts, _cwd), do: opts

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_), do: 60_000

  defp terminal_event?(kind), do: kind in [:result, :error, :run_completed]
end

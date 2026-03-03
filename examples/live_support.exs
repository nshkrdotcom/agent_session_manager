defmodule ASM.Examples.LiveSupport do
  @moduledoc false

  alias ASM.{Error, Event, Provider}

  @spec prompt_from_argv_or_default(String.t()) :: String.t()
  def prompt_from_argv_or_default(default) when is_binary(default) do
    argv =
      System.argv()
      |> Enum.reject(&(&1 == "--"))

    case Enum.join(argv, " ") do
      "" -> default
      prompt -> prompt
    end
  end

  @spec ensure_cli!(Provider.provider_name(), keyword()) :: :ok
  def ensure_cli!(provider, resolver_opts \\ []) do
    case ASM.Provider.Resolver.resolve(provider, resolver_opts) do
      {:ok, _command_spec} ->
        :ok

      {:error, %Error{} = error} ->
        details = provider_install_hint(provider)

        IO.puts("""
        CLI resolution failed for #{inspect(provider)}.
        #{Exception.message(error)}
        #{details}
        """)

        System.halt(1)
    end
  end

  @spec stream_and_collect!(Provider.provider_name(), String.t(), keyword()) :: ASM.Result.t()
  def stream_and_collect!(provider, prompt, opts \\ [])
      when is_binary(prompt) and is_list(opts) do
    session_id = "example-#{provider}-#{System.system_time(:millisecond)}"

    start_opts =
      opts
      |> Keyword.drop([:session_id])
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:session_id, session_id)

    with {:ok, session} <- ASM.start_session(start_opts) do
      try do
        events = session |> ASM.stream(prompt, opts) |> Enum.to_list()
        Enum.each(events, &print_event/1)

        fail_if_error_events!(events)

        result = ASM.Stream.final_result(events)
        print_result(result)
        result
      after
        _ = ASM.stop_session(session)
      end
    else
      {:error, %Error{} = error} ->
        IO.puts("failed to start session: #{Exception.message(error)}")
        System.halt(1)

      {:error, other} ->
        IO.puts("failed to start session: #{inspect(other)}")
        System.halt(1)
    end
  rescue
    error ->
      IO.puts("stream execution failed: #{Exception.message(error)}")
      System.halt(1)
  end

  @spec print_event(Event.t()) :: :ok
  def print_event(%Event{kind: :assistant_delta, payload: %ASM.Message.Partial{delta: delta}}) do
    IO.write(delta)
    :ok
  end

  def print_event(%Event{
        kind: :assistant_message,
        payload: %ASM.Message.Assistant{content: blocks}
      }) do
    text =
      blocks
      |> Enum.flat_map(fn
        %ASM.Content.Text{text: value} -> [value]
        _ -> []
      end)
      |> Enum.join()

    unless text == "", do: IO.puts(text)
    :ok
  end

  def print_event(%Event{kind: :result, payload: %ASM.Message.Result{stop_reason: stop_reason}}) do
    IO.puts("\n[result stop_reason=#{inspect(stop_reason)}]")
    :ok
  end

  def print_event(%Event{kind: :error, payload: %ASM.Message.Error{} = payload}) do
    IO.puts("\n[error #{payload.kind}] #{payload.message}")
    :ok
  end

  def print_event(_event), do: :ok

  @spec print_result(ASM.Result.t()) :: :ok
  def print_result(result) do
    IO.puts("""

    ----
    run_id: #{result.run_id}
    session_id: #{result.session_id}
    stop_reason: #{inspect(result.stop_reason)}
    text: #{inspect(result.text)}
    ----
    """)

    :ok
  end

  defp provider_install_hint(provider) do
    case Provider.resolve(provider) do
      {:ok, %Provider{install_command: command}} when is_binary(command) and command != "" ->
        "Install hint: #{command}"

      _ ->
        "Install hint: ensure the provider CLI is installed and on PATH."
    end
  end

  defp fail_if_error_events!(events) do
    errors =
      events
      |> Enum.filter(fn
        %Event{kind: :error, payload: %ASM.Message.Error{}} -> true
        _ -> false
      end)
      |> Enum.map(fn %Event{payload: %ASM.Message.Error{} = payload} ->
        "[#{payload.kind}] #{payload.message}"
      end)

    if errors != [] do
      IO.puts("\nrun failed with error events:")
      Enum.each(errors, &IO.puts("  - " <> &1))
      System.halt(1)
    end
  end
end

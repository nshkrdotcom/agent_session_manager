defmodule ASM.Examples.LiveSupport do
  @moduledoc false

  alias ASM.{Error, Event, Provider}

  @cli_commands %{
    claude: "claude",
    gemini: "gemini",
    codex: "codex",
    amp: "amp"
  }

  @install_hints %{
    claude: "npm install -g @anthropic-ai/claude-code",
    gemini: "npm install -g @google/gemini-cli",
    codex: "npm install -g @openai/codex",
    amp: "install the Amp CLI and ensure it is available on PATH"
  }

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
    case cli_check(provider, resolver_opts) do
      :ok ->
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

  @spec cli_available?(Provider.provider_name(), keyword()) :: boolean()
  def cli_available?(provider, opts \\ []) do
    cli_check(provider, opts) == :ok
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

  @spec run_session_feature_matrix!(
          Provider.provider_name(),
          String.t(),
          String.t(),
          keyword()
        ) :: %{stream: ASM.Result.t(), query: ASM.Result.t(), final_cost: map()}
  def run_session_feature_matrix!(provider, stream_prompt, query_prompt, opts \\ [])
      when is_binary(stream_prompt) and is_binary(query_prompt) and is_list(opts) do
    session_id = "feature-#{provider}-#{System.system_time(:millisecond)}"

    start_opts =
      opts
      |> Keyword.drop([:session_id])
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:session_id, session_id)

    with {:ok, session} <- ASM.start_session(start_opts) do
      try do
        IO.puts("session_id=#{ASM.session_id(session)} provider=#{provider}")
        IO.puts("health(before)=#{inspect(ASM.health(session))}")

        events = session |> ASM.stream(stream_prompt, opts) |> Enum.to_list()
        Enum.each(events, &print_event/1)
        fail_if_error_events!(events)
        stream_result = ASM.Stream.final_result(events)
        print_result(stream_result)

        query_result =
          case ASM.query(session, query_prompt, opts) do
            {:ok, result} ->
              IO.puts("\n[query result]")
              print_result(result)
              result

            {:error, %Error{} = error} ->
              IO.puts("query failed: #{Exception.message(error)}")
              System.halt(1)
          end

        final_cost = ASM.cost(session)
        IO.puts("health(after)=#{inspect(ASM.health(session))}")
        IO.puts("session_cost=#{inspect(final_cost)}")

        %{stream: stream_result, query: query_result, final_cost: final_cost}
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
      IO.puts("feature matrix execution failed: #{Exception.message(error)}")
      System.halt(1)
  end

  @spec print_event(Event.t()) :: :ok
  def print_event(%Event{} = event) do
    case Event.legacy_payload(event) do
      %ASM.Message.Partial{delta: delta} ->
        IO.write(delta)
        :ok

      %ASM.Message.Assistant{content: blocks} ->
        text =
          blocks
          |> Enum.flat_map(fn
            %ASM.Content.Text{text: value} -> [value]
            _ -> []
          end)
          |> Enum.join()

        unless text == "", do: IO.puts(text)
        :ok

      %ASM.Message.Result{stop_reason: stop_reason} ->
        IO.puts("\n[result stop_reason=#{inspect(stop_reason)}]")
        :ok

      %ASM.Message.Error{} = payload ->
        IO.puts("\n[error #{payload.kind}] #{payload.message}")
        :ok

      _other ->
        :ok
    end
  end

  def print_event(_event), do: :ok

  @spec print_result(ASM.Result.t()) :: :ok
  def print_result(result) do
    IO.puts("""

    ----
    run_id: #{result.run_id}
    session_id: #{result.session_id}
    stop_reason: #{inspect(result.stop_reason)}
    duration_ms: #{inspect(result.duration_ms)}
    cost: #{inspect(result.cost)}
    error: #{inspect(result.error)}
    text: #{inspect(result.text)}
    ----
    """)

    :ok
  end

  defp provider_install_hint(provider) do
    "Install hint: #{Map.get(@install_hints, provider, "ensure the provider CLI is installed and on PATH.")}"
  end

  defp fail_if_error_events!(events) do
    errors =
      events
      |> Enum.filter(fn
        %Event{kind: :error} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn
        %Event{} = event ->
          case Event.legacy_payload(event) do
            %ASM.Message.Error{} = payload -> ["[#{payload.kind}] #{payload.message}"]
            _ -> []
          end
      end)

    if errors != [] do
      IO.puts("\nrun failed with error events:")
      Enum.each(errors, &IO.puts("  - " <> &1))
      System.halt(1)
    end
  end

  defp cli_check(provider, opts) do
    with {:ok, %Provider{name: resolved_provider}} <- Provider.resolve(provider),
         :ok <- ensure_executable(resolved_provider, Keyword.get(opts, :cli_path)) do
      :ok
    end
  end

  defp ensure_executable(_provider, path) when is_binary(path) and path != "" do
    if File.regular?(path) do
      :ok
    else
      {:error, Error.new(:cli_not_found, :provider, "CLI executable not found at #{path}")}
    end
  end

  defp ensure_executable(provider, _path) do
    command = Map.get(@cli_commands, provider)

    if is_binary(command) and System.find_executable(command) do
      :ok
    else
      {:error,
       Error.new(
         :cli_not_found,
         :provider,
         "CLI executable #{inspect(command)} not found on PATH"
       )}
    end
  end
end

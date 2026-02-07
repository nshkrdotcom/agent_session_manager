defmodule CommonSurface do
  @moduledoc false

  # Provider-agnostic example showing the full normalized SessionManager lifecycle.
  #
  # Demonstrates that the same code works identically across Claude and Codex
  # providers via the ProviderAdapter behaviour.

  alias AgentSessionManager.Adapters.{ClaudeAdapter, CodexAdapter, InMemorySessionStore}
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompts [
    "What is the BEAM virtual machine? Keep your answer to two sentences.",
    "How does OTP supervision work? Keep your answer to two sentences."
  ]

  # ============================================================================
  # Entry Point
  # ============================================================================

  @doc """
  Main entry point for the common surface example.
  """
  def main(args) do
    provider = parse_args(args)
    print_header(provider)

    case run_example(provider) do
      :ok ->
        print_success("Common surface example completed successfully!")
        System.halt(0)

      {:error, error} ->
        print_error("Example failed: #{format_error(error)}")
        System.halt(1)
    end
  end

  # ============================================================================
  # Command Line Argument Parsing
  # ============================================================================

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, help: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex"] do
      print_error("Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/common_surface.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude or codex). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY

    Examples:
      mix run examples/common_surface.exs --provider claude
      mix run examples/common_surface.exs --provider codex
    """)
  end

  # ============================================================================
  # Main Example Logic
  # ============================================================================

  defp run_example(provider) do
    with {:ok, store} <- start_store(),
         _ = print_step(1, "Session Store Started"),
         _ = print_info("InMemorySessionStore ready"),
         {:ok, adapter} <- start_adapter(provider),
         _ = print_step(2, "Provider Adapter Started (#{provider})"),
         _ = print_info("Adapter ready"),
         {:ok, session} <- create_session(store, adapter, provider),
         _ = print_step(3, "Session Created"),
         _ = print_info("Session ID: #{session.id}"),
         {:ok, _activated} <- SessionManager.activate_session(store, session.id),
         _ = print_info("Session activated"),
         {:ok, run_results} <- execute_runs(store, adapter, session),
         _ = print_step(4, "Runs Completed"),
         {:ok, events_summary} <- summarize_events(store, session, run_results),
         _ = print_step(5, "Event Summary"),
         _ = print_events_summary(events_summary),
         {:ok, _completed} <- SessionManager.complete_session(store, session.id),
         _ = print_step(6, "Session Completed"),
         _ = print_info("Session status: completed"),
         _ = print_final_summary(run_results) do
      :ok
    else
      {:error, error} ->
        print_error(format_error(error))
        {:error, error}
    end
  end

  # ============================================================================
  # Infrastructure Setup
  # ============================================================================

  defp start_store do
    case InMemorySessionStore.start_link([]) do
      {:ok, store} ->
        {:ok, store}

      {:error, reason} ->
        {:error, Error.new(:internal_error, "Store start failed: #{inspect(reason)}")}
    end
  end

  defp start_adapter("claude") do
    case ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001", tools: []) do
      {:ok, adapter} ->
        {:ok, adapter}

      {:error, reason} ->
        {:error, Error.new(:sdk_not_available, "Claude adapter failed: #{inspect(reason)}")}
    end
  end

  defp start_adapter("codex") do
    case CodexAdapter.start_link(working_directory: File.cwd!()) do
      {:ok, adapter} ->
        {:ok, adapter}

      {:error, reason} ->
        {:error, Error.new(:sdk_not_available, "Codex adapter failed: #{inspect(reason)}")}
    end
  end

  defp create_session(store, adapter, provider) do
    SessionManager.start_session(store, adapter, %{
      agent_id: "common-surface-#{provider}",
      context: %{
        system_prompt: "You are a helpful assistant. Keep your responses concise."
      },
      tags: ["example", "common-surface"]
    })
  end

  # ============================================================================
  # Run Execution
  # ============================================================================

  defp execute_runs(store, adapter, session) do
    results =
      @prompts
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {prompt, index}, acc ->
        print_divider("Run #{index}")
        print_info("Prompt: \"#{prompt}\"")
        IO.puts("")

        case execute_single_run(store, adapter, session, prompt) do
          {:ok, result} ->
            IO.puts("")
            print_info("Run #{index} complete")
            {:cont, acc ++ [{index, result}]}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)

    case results do
      {:error, error} -> {:error, error}
      run_results -> {:ok, run_results}
    end
  end

  defp execute_single_run(store, adapter, session, prompt) do
    with {:ok, run} <-
           SessionManager.start_run(store, adapter, session.id, %{
             messages: [%{role: "user", content: prompt}]
           }),
         _ = print_info("Run ID: #{run.id}") do
      event_callback = fn event_data -> handle_live_event(event_data) end

      start_time = System.monotonic_time(:millisecond)

      result =
        AgentSessionManager.Ports.ProviderAdapter.execute(adapter, run, session,
          event_callback: event_callback,
          timeout: 120_000
        )

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      case result do
        {:ok, adapter_result} ->
          {:ok, Map.put(adapter_result, :duration_ms, duration_ms) |> Map.put(:run_id, run.id)}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # ============================================================================
  # Event Handling
  # ============================================================================

  defp handle_live_event(%{type: :message_streamed, data: data}) do
    content = data[:delta] || data[:content] || ""
    IO.write(IO.ANSI.cyan() <> content <> IO.ANSI.reset())
  end

  defp handle_live_event(%{type: type, data: data}) do
    timestamp = format_timestamp(DateTime.utc_now())
    type_str = format_event_type(type)

    case type do
      :run_started ->
        model = data[:model] || "default"
        IO.puts(:stderr, "#{timestamp} #{type_str} model=#{model}")

      :run_completed ->
        stop_reason = data[:stop_reason] || data[:status] || "unknown"
        IO.puts(:stderr, "#{timestamp} #{type_str} stop_reason=#{stop_reason}")

      :token_usage_updated ->
        input = trunc(data[:input_tokens] || 0)
        output = trunc(data[:output_tokens] || 0)
        IO.puts(:stderr, "#{timestamp} #{type_str} input=#{input} output=#{output}")

      _ ->
        IO.puts(:stderr, "#{timestamp} #{type_str}")
    end
  end

  defp handle_live_event(_event), do: :ok

  # ============================================================================
  # Event Summary
  # ============================================================================

  defp summarize_events(store, session, run_results) do
    summaries =
      Enum.map(run_results, fn {index, result} ->
        run_id = result[:run_id]

        {:ok, events} =
          SessionStore.get_events(store, session.id, run_id: run_id)

        type_counts =
          events
          |> Enum.group_by(& &1.type)
          |> Enum.map(fn {type, evts} -> {type, length(evts)} end)
          |> Enum.sort_by(fn {_type, count} -> -count end)

        {index, length(events), type_counts}
      end)

    {:ok, summaries}
  end

  defp print_events_summary(summaries) do
    Enum.each(summaries, fn {index, total, type_counts} ->
      print_info("Run #{index}: #{total} events")

      Enum.each(type_counts, fn {type, count} ->
        IO.puts("    #{type}: #{count}")
      end)
    end)
  end

  # ============================================================================
  # Final Summary
  # ============================================================================

  defp print_final_summary(run_results) do
    print_divider("Final Summary")

    total_runs = length(run_results)
    IO.puts("  Runs:          #{total_runs}")

    total_input =
      Enum.reduce(run_results, 0, fn {_i, r}, acc ->
        acc + trunc(r.token_usage[:input_tokens] || 0)
      end)

    total_output =
      Enum.reduce(run_results, 0, fn {_i, r}, acc ->
        acc + trunc(r.token_usage[:output_tokens] || 0)
      end)

    IO.puts("  Input tokens:  #{total_input}")
    IO.puts("  Output tokens: #{total_output}")
    IO.puts("  Total tokens:  #{total_input + total_output}")

    total_duration =
      Enum.reduce(run_results, 0, fn {_i, r}, acc ->
        acc + (r[:duration_ms] || 0)
      end)

    IO.puts("  Total time:    #{total_duration}ms")
    IO.puts("")
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_header(provider) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "AgentSessionManager - Common Surface Example" <> IO.ANSI.reset())
    IO.puts(String.duplicate("=", 50))
    IO.puts("Provider: #{provider}")
    IO.puts(String.duplicate("=", 50))
    IO.puts("")
  end

  defp print_step(num, title) do
    IO.puts("")

    IO.puts(
      IO.ANSI.bright() <>
        IO.ANSI.blue() <> "Step #{num}: #{title}" <> IO.ANSI.reset()
    )

    IO.puts(String.duplicate("-", 40))
  end

  defp print_divider(title) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "--- #{title} ---" <> IO.ANSI.reset())
    IO.puts("")
  end

  defp print_info(message) do
    IO.puts(IO.ANSI.green() <> "  [INFO] " <> IO.ANSI.reset() <> message)
  end

  defp print_error(message) do
    IO.puts(IO.ANSI.red() <> "  [ERROR] " <> IO.ANSI.reset() <> message)
  end

  defp print_success(message) do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> IO.ANSI.green() <> message <> IO.ANSI.reset())
    IO.puts("")
  end

  defp format_error(%Error{} = error), do: "#{error.code}: #{error.message}"
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp format_timestamp(datetime) do
    time = DateTime.to_time(datetime)
    "#{pad(time.hour)}:#{pad(time.minute)}:#{pad(time.second)}"
  end

  defp pad(num), do: String.pad_leading(Integer.to_string(num), 2, "0")

  defp format_event_type(type) do
    type_str = Atom.to_string(type)
    color = event_type_color(type)
    "#{color}[#{String.pad_trailing(type_str, 20)}]#{IO.ANSI.reset()}"
  end

  defp event_type_color(:run_started), do: IO.ANSI.green()
  defp event_type_color(:run_completed), do: IO.ANSI.green()
  defp event_type_color(:message_received), do: IO.ANSI.blue()
  defp event_type_color(:message_streamed), do: IO.ANSI.cyan()
  defp event_type_color(:token_usage_updated), do: IO.ANSI.yellow()
  defp event_type_color(:error_occurred), do: IO.ANSI.red()
  defp event_type_color(:run_failed), do: IO.ANSI.red()
  defp event_type_color(_), do: IO.ANSI.white()
end

CommonSurface.main(System.argv())

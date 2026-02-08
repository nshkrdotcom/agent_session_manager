#!/usr/bin/env elixir

defmodule ContractSurfaceLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.SessionManager

  @prompt "Reply with exactly one word: acknowledged"

  def main(args) do
    provider = parse_args(args)

    IO.puts("\n=== Contract Surface Live Example (#{provider}) ===\n")

    case run(provider) do
      :ok ->
        IO.puts("\nDone.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{format_error(reason)}")
        System.halt(1)
    end
  end

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

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""

    Usage: mix run examples/contract_surface_live.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/contract_surface_live.exs --provider claude
      mix run examples/contract_surface_live.exs --provider codex
      mix run examples/contract_surface_live.exs --provider amp
    """)
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "contract-surface-#{provider}",
             context: %{system_prompt: "Be concise and deterministic."},
             tags: ["example", "contract-surface", provider]
           }),
         {:ok, _} <- SessionManager.activate_session(store, session.id),
         {:ok, run} <-
           SessionManager.start_run(store, adapter, session.id, %{
             messages: [%{role: "user", content: @prompt}]
           }),
         {:ok, result, callback_events} <- execute_and_collect(store, adapter, run.id),
         :ok <- print_summary(provider, session, run, result, callback_events),
         {:ok, _} <- SessionManager.complete_session(store, session.id) do
      :ok
    end
  end

  defp execute_and_collect(store, adapter, run_id) do
    parent = self()

    callback = fn event ->
      send(parent, {:adapter_event, event})
    end

    case SessionManager.execute_run(store, adapter, run_id, event_callback: callback) do
      {:ok, result} ->
        callback_events = collect_callback_events([])
        {:ok, result, callback_events}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp collect_callback_events(acc) do
    receive do
      {:adapter_event, event} ->
        collect_callback_events([event | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp print_summary(provider, session, run, result, callback_events) do
    run_completed = Enum.find(callback_events, &(&1.type == :run_completed))

    run_completed_token_usage =
      if run_completed do
        run_completed.data[:token_usage]
      else
        nil
      end

    IO.puts("Provider:            #{provider}")
    IO.puts("Session ID:          #{session.id}")
    IO.puts("Run ID:              #{run.id}")
    IO.puts("Result output:       #{inspect(result.output.content)}")
    IO.puts("Result token_usage:  #{inspect(result.token_usage)}")
    IO.puts("Result events count: #{length(result.events)}")
    IO.puts("Callback events:     #{length(callback_events)}")

    IO.puts(
      "Run completed event includes token_usage: #{if(run_completed_token_usage, do: "yes", else: "no")}"
    )

    if result.events != [] do
      first = hd(result.events).type
      last = List.last(result.events).type
      IO.puts("Result events span:  #{first} -> #{last}")
    end

    :ok
  end

  defp start_adapter("claude"), do: ClaudeAdapter.start_link([])
  defp start_adapter("codex"), do: CodexAdapter.start_link(working_directory: File.cwd!())
  defp start_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())

  defp format_error(%Error{code: code, message: message}), do: "#{code}: #{message}"
  defp format_error(other), do: inspect(other)
end

ContractSurfaceLive.main(System.argv())

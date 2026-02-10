defmodule NoopStoreRunOnce do
  @moduledoc false

  # One-shot execution using DurableStore NoopStore mode.
  #
  # This runs the full execution path and returns output/events, but does not
  # durably persist session/run/event data.

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    NoopStore
  }

  alias AgentSessionManager.SessionManager

  @prompt "Explain what OTP supervisors do in two short sentences."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== NoopStore run_once (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("")
        IO.puts("Done.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
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

    Usage: mix run examples/noop_store_run_once.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Examples:
      mix run examples/noop_store_run_once.exs --provider claude
      mix run examples/noop_store_run_once.exs --provider codex
      mix run examples/noop_store_run_once.exs --provider amp
    """)
  end

  defp run(provider) do
    with {:ok, adapter} <- start_adapter(provider) do
      IO.puts("Prompt: #{@prompt}")
      IO.puts("")

      event_callback = fn event ->
        if event.type in [:run_started, :run_completed, :run_failed] do
          IO.puts("event: #{event.type}")
        end
      end

      case SessionManager.run_once(
             NoopStore,
             adapter,
             %{messages: [%{role: "user", content: @prompt}]},
             context: %{system_prompt: "You are concise and practical."},
             event_callback: event_callback
           ) do
        {:ok, result} ->
          IO.puts("Response: #{inspect(result.output)}")
          IO.puts("Tokens:   #{inspect(result.token_usage)}")
          IO.puts("Events returned in result: #{length(result.events)}")
          IO.puts("NoopStore does not durably persist these events.")
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp start_adapter("claude"), do: ClaudeAdapter.start_link([])
  defp start_adapter("codex"), do: CodexAdapter.start_link(working_directory: File.cwd!())
  defp start_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())
end

NoopStoreRunOnce.main(System.argv())

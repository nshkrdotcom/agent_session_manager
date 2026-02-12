defmodule InteractiveInterruptExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @initial_prompt """
  Write a detailed explanation of how photosynthesis works, covering the light \
  reactions and the Calvin cycle. Be thorough and take your time.\
  """

  @followup_prompt """
  Good, but I changed my mind. Summarize everything you said so far in exactly \
  3 bullet points, then stop.\
  """

  @cancel_after_ms 4_000
  @run1_timeout_ms 90_000

  def main(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, delay: :integer, help: :boolean],
        aliases: [p: :provider, d: :delay, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"
    delay = opts[:delay] || @cancel_after_ms

    IO.puts("")
    IO.puts("=== Interactive Interrupt Example (#{provider}) ===")
    IO.puts("")

    case run(provider, delay) do
      :ok ->
        IO.puts("\nInteractive interrupt example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nInteractive interrupt example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider, cancel_delay_ms) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider) do
      demo_interrupt_and_continue(store, adapter, cancel_delay_ms)
    end
  end

  defp demo_interrupt_and_continue(store, adapter, cancel_delay_ms) do
    # -- Phase 1: Start a session and first run --------------------------------
    IO.puts("--- Phase 1: Start session and first run ---\n")

    {:ok, session} =
      SessionManager.start_session(store, adapter, %{agent_id: "interrupt-demo"})

    {:ok, _active} = SessionManager.activate_session(store, session.id)

    IO.puts("  Session: #{session.id}")
    IO.puts("  Prompt: #{String.trim(@initial_prompt)}")
    IO.puts("")

    {:ok, run1} =
      SessionManager.start_run(store, adapter, session.id, %{
        messages: [%{role: "user", content: @initial_prompt}]
      })

    IO.puts("  Run 1: #{run1.id}")
    IO.puts("  Streaming for ~#{cancel_delay_ms}ms before cancelling...\n")

    parent = self()
    token_count = :counters.new(1, [:atomics])
    chunk_ref = make_ref()

    exec_pid =
      spawn(fn ->
        result =
          SessionManager.execute_run(store, adapter, run1.id,
            event_callback: fn event ->
              render_event(event)

              if event.type == :message_streamed do
                :counters.add(token_count, 1, 1)

                if :counters.get(token_count, 1) == 1,
                  do: send(parent, {chunk_ref, :streamed_chunk})
              end
            end
          )

        send(parent, {:run_finished, run1.id, result})
      end)

    # Wait for first streamed chunk before applying the cancellation delay.
    saw_first_chunk =
      wait_for_first_streamed_chunk(chunk_ref, first_chunk_wait_timeout_ms(cancel_delay_ms))

    unless saw_first_chunk do
      IO.puts(
        "\n\n  >>> No streamed chunks observed yet; issuing best-effort cancel anyway <<<\n"
      )
    end

    if saw_first_chunk, do: Process.sleep(cancel_delay_ms)

    tokens_before = :counters.get(token_count, 1)
    IO.puts("\n\n  >>> Cancelling run after #{tokens_before} streamed chunks <<<\n")

    _ = SessionManager.cancel_run(store, adapter, run1.id)

    # Wait for the adapter to finish.
    run1_id = run1.id

    run1_result =
      receive do
        {:run_finished, ^run1_id, result} -> result
      after
        @run1_timeout_ms -> {:error, :timeout}
      end

    stop_process(exec_pid)

    case run1_result do
      {:ok, r} ->
        IO.puts("  Run 1 status: completed (adapter finished before cancel took effect)")
        IO.puts("  Output tokens: #{inspect(get_in(r, [:token_usage, :output_tokens]))}")

      {:error, %Error{code: :run_cancelled}} ->
        IO.puts("  Run 1 status: cancelled")

      {:error, %Error{} = e} ->
        IO.puts("  Run 1 status: #{e.code}")

      {:error, :timeout} ->
        IO.puts("  Run 1 status: timed out waiting for adapter")
    end

    # Show events from run 1.
    {:ok, run1_events} = SessionStore.get_events(store, session.id, run_id: run1.id)
    run1_types = run1_events |> Enum.map(& &1.type) |> Enum.uniq()
    IO.puts("  Run 1 event types: #{inspect(run1_types)}")

    IO.puts("")

    # -- Phase 2: Follow-up run in the SAME session ----------------------------
    IO.puts("--- Phase 2: Follow-up run in SAME session ---\n")

    IO.puts("  Follow-up prompt: #{String.trim(@followup_prompt)}")
    IO.puts("")

    {:ok, run2} =
      SessionManager.start_run(store, adapter, session.id, %{
        messages: [%{role: "user", content: @followup_prompt}]
      })

    IO.puts("  Run 2: #{run2.id}")
    IO.puts("  Streaming to completion...\n")

    run2_result =
      SessionManager.execute_run(store, adapter, run2.id,
        continuation: :replay,
        event_callback: &render_event/1
      )

    IO.puts("")

    case run2_result do
      {:ok, r} ->
        IO.puts("  Run 2 status: completed")
        IO.puts("  Output tokens: #{inspect(get_in(r, [:token_usage, :output_tokens]))}")

      {:error, %Error{} = e} ->
        IO.puts("  Run 2 status: #{e.code}")
    end

    {:ok, run2_events} = SessionStore.get_events(store, session.id, run_id: run2.id)
    run2_types = run2_events |> Enum.map(& &1.type) |> Enum.uniq()
    IO.puts("  Run 2 event types: #{inspect(run2_types)}")

    IO.puts("")

    # -- Phase 3: Summary -----------------------------------------------------
    IO.puts("--- Summary ---\n")

    {:ok, all_events} = SessionStore.get_events(store, session.id)
    IO.puts("  Session: #{session.id}")
    IO.puts("  Total runs: 2 (run 1 interrupted, run 2 completed)")
    IO.puts("  Total events: #{length(all_events)}")
    IO.puts("  Run 1 events: #{length(run1_events)}")
    IO.puts("  Run 2 events: #{length(run2_events)}")
    IO.puts("")
    IO.puts("  Key points demonstrated:")
    IO.puts("    1. Started a long-running response in a session")
    IO.puts("    2. Cancelled it mid-stream with SessionManager.cancel_run/3")
    IO.puts("    3. Started a NEW run in the SAME session with a follow-up prompt")
    IO.puts("    4. Second run streamed to completion with session continuity")
    IO.puts("")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Streaming event renderer
  # ---------------------------------------------------------------------------

  defp render_event(%{type: :message_streamed, data: data}) when is_map(data) do
    delta = Map.get(data, :delta) || Map.get(data, :content) || ""
    IO.write(delta)
  end

  defp render_event(%{type: :tool_call_started, data: data}) when is_map(data) do
    IO.puts("\n  [tool_call_started] #{Map.get(data, :tool_name)}")
  end

  defp render_event(%{type: :run_completed}), do: IO.puts("\n  [run_completed]")
  defp render_event(%{type: :run_cancelled}), do: IO.puts("\n  [run_cancelled]")
  defp render_event(_), do: :ok

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def wait_for_first_streamed_chunk(ref, timeout_ms) do
    receive do
      {^ref, :streamed_chunk} -> true
    after
      timeout_ms -> false
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp first_chunk_wait_timeout_ms(cancel_delay_ms), do: max(cancel_delay_ms * 2, 12_000)

  defp start_adapter("claude"), do: ClaudeAdapter.start_link([])
  defp start_adapter("codex"), do: CodexAdapter.start_link(working_directory: File.cwd!())
  defp start_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())

  defp start_adapter(other) do
    {:error, Error.new(:validation_error, "Unknown provider: #{other}")}
  end

  defp print_usage do
    IO.puts("""
    Usage: mix run examples/interactive_interrupt.exs [options]

    Options:
      --provider, -p <name>   Provider to use (claude, codex, amp). Default: claude
      --delay, -d <ms>        Milliseconds to stream before cancelling. Default: #{@cancel_after_ms}
      --help, -h              Show this help

    This example demonstrates interrupt-and-continue in a single session:
      1. Starts a long-running response
      2. Cancels it mid-stream after --delay milliseconds
      3. Sends a follow-up prompt in the SAME session
      4. Streams the follow-up response to completion

    Examples:
      mix run examples/interactive_interrupt.exs --provider claude
      mix run examples/interactive_interrupt.exs --provider claude --delay 2000
      mix run examples/interactive_interrupt.exs --provider codex
      mix run examples/interactive_interrupt.exs --provider amp
    """)
  end
end

InteractiveInterruptExample.main(System.argv())

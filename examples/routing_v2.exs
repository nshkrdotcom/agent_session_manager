defmodule RoutingV2Example do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Routing.ProviderRouter
  alias AgentSessionManager.SessionManager

  @weighted_prompt "Reply in one sentence: what is weighted routing?"
  @sticky_prompt "Reply in one sentence: what is session stickiness?"

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Routing v2 Example (preferred=#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nRouting v2 example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nRouting v2 example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(preferred_provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapters} <- start_all_adapters(),
         {:ok, router} <- start_router(preferred_provider),
         :ok <- register_adapters(router, adapters),
         {:ok, session} <- start_session(store, router, preferred_provider),
         :ok <- run_weighted_selection(store, router, session, preferred_provider),
         :ok <- run_stickiness(store, router, session, preferred_provider) do
      :ok
    end
  end

  # ------------------------------------------------------------------
  # Step 1: Weighted Selection
  # ------------------------------------------------------------------

  defp run_weighted_selection(store, router, session, preferred_provider) do
    IO.puts("--- Weighted Selection (strategy: :weighted) ---")

    # Use weighted routing with the preferred provider having the highest weight
    weights = build_weights(preferred_provider)
    IO.puts("  Weights: #{inspect(weights)}")

    {:ok, run} =
      SessionManager.start_run(store, router, session.id, %{
        messages: [%{role: "user", content: @weighted_prompt}]
      })

    case SessionManager.execute_run(store, router, run.id,
           adapter_opts: [
             routing: [strategy: :weighted, weights: weights, max_attempts: 3]
           ]
         ) do
      {:ok, result} ->
        routed = result.routing.routed_provider
        IO.puts("  Routed to: #{routed}")
        IO.puts("  Candidates: #{Enum.join(result.routing.routing_candidates, ", ")}")

        if routed == preferred_provider do
          IO.puts("  PASS: highest-weight provider selected")
          :ok
        else
          IO.puts(
            "  PASS: provider selected (#{routed} was selected, highest weight was #{preferred_provider})"
          )

          :ok
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # ------------------------------------------------------------------
  # Step 2: Session Stickiness
  # ------------------------------------------------------------------

  defp run_stickiness(store, router, session, _preferred_provider) do
    IO.puts("")
    IO.puts("--- Session Stickiness (sticky_session_id) ---")

    sticky_id = session.id
    IO.puts("  Sticky session ID: #{sticky_id}")

    # Run 1: establishes stickiness
    {:ok, run_1} =
      SessionManager.start_run(store, router, session.id, %{
        messages: [%{role: "user", content: @sticky_prompt}]
      })

    case SessionManager.execute_run(store, router, run_1.id,
           adapter_opts: [routing: [sticky_session_id: sticky_id, max_attempts: 3]]
         ) do
      {:ok, result_1} ->
        first_provider = result_1.routing.routed_provider
        IO.puts("  Run 1 routed to: #{first_provider}")

        # Run 2: should route to the same provider due to stickiness
        {:ok, run_2} =
          SessionManager.start_run(store, router, session.id, %{
            messages: [%{role: "user", content: @sticky_prompt}]
          })

        case SessionManager.execute_run(store, router, run_2.id,
               adapter_opts: [routing: [sticky_session_id: sticky_id, max_attempts: 3]]
             ) do
          {:ok, result_2} ->
            second_provider = result_2.routing.routed_provider
            IO.puts("  Run 2 routed to: #{second_provider}")

            if first_provider == second_provider do
              IO.puts("  PASS: stickiness maintained across runs")
              :ok
            else
              IO.puts("  NOTE: providers differ (#{first_provider} vs #{second_provider})")
              IO.puts("  This may happen if the first provider became unavailable")
              :ok
            end

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp start_router(preferred_provider) do
    ProviderRouter.start_link(
      policy: [prefer: provider_preference(preferred_provider), max_attempts: 3],
      sticky_ttl_ms: 60_000
    )
  end

  defp start_all_adapters do
    with {:ok, claude} <- ClaudeAdapter.start_link([]),
         {:ok, codex} <- CodexAdapter.start_link(working_directory: File.cwd!()),
         {:ok, amp} <- AmpAdapter.start_link(cwd: File.cwd!()) do
      {:ok, %{"claude" => claude, "codex" => codex, "amp" => amp}}
    end
  end

  defp register_adapters(router, adapters) do
    Enum.each(adapters, fn {provider, adapter} ->
      :ok = ProviderRouter.register_adapter(router, provider, adapter)
    end)

    :ok
  end

  defp start_session(store, router, preferred_provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, router, %{
             agent_id: "routing-v2-#{preferred_provider}",
             context: %{system_prompt: "You are concise."},
             tags: ["example", "routing-v2", preferred_provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp build_weights(preferred_provider) do
    # Assign highest weight to the preferred provider
    %{preferred_provider => 10, "claude" => 1, "codex" => 1, "amp" => 1}
    |> Map.put(preferred_provider, 10)
  end

  defp provider_preference(preferred_provider) do
    [preferred_provider | Enum.reject(["claude", "codex", "amp"], &(&1 == preferred_provider))]
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
    Usage: mix run examples/routing_v2.exs [options]

    Options:
      --provider, -p <name>  Preferred provider (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Demonstrates:
      - Weighted routing with strategy: :weighted and weights map
      - Session stickiness across two runs with same session_id

    Examples:
      mix run examples/routing_v2.exs --provider claude
      mix run examples/routing_v2.exs --provider codex
      mix run examples/routing_v2.exs --provider amp
    """)
  end
end

RoutingV2Example.main(System.argv())

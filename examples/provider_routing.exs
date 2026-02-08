defmodule ProviderRoutingExample do
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

  @capability_prompt "Reply in one sentence: what is provider routing?"
  @failover_prompt "Reply in one sentence: what is failover?"

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Provider Routing Example (preferred=#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nProvider routing example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nProvider routing example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(preferred_provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapters} <- start_all_adapters(),
         {:ok, router} <- start_router(preferred_provider),
         :ok <- register_adapters(router, adapters),
         {:ok, session} <- start_session(store, router, preferred_provider),
         {:ok, _capability_run, capability_result} <-
           run_capability_selection(store, router, session.id, preferred_provider),
         :ok <- assert_capability_selection(capability_result, preferred_provider),
         :ok <- simulate_provider_outage(adapters, preferred_provider),
         {:ok, _failover_run, failover_result} <-
           run_failover(store, router, session.id),
         :ok <- assert_failover(failover_result, preferred_provider) do
      print_summary(capability_result, failover_result)
      :ok
    end
  end

  defp start_router(preferred_provider) do
    ProviderRouter.start_link(
      policy: [prefer: provider_preference(preferred_provider), max_attempts: 3]
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
             agent_id: "router-#{preferred_provider}",
             context: %{system_prompt: "You are concise."},
             tags: ["example", "routing", preferred_provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp run_capability_selection(store, router, session_id, preferred_provider) do
    required_capability = capability_requirement_for(preferred_provider)

    execute_prompt(
      store,
      router,
      session_id,
      @capability_prompt,
      adapter_opts: [routing: [required_capabilities: [required_capability], max_attempts: 3]]
    )
  end

  defp run_failover(store, router, session_id) do
    execute_prompt(store, router, session_id, @failover_prompt,
      adapter_opts: [routing: [max_attempts: 3]]
    )
  end

  defp execute_prompt(store, router, session_id, prompt, execute_opts) do
    with {:ok, run} <-
           SessionManager.start_run(store, router, session_id, %{
             messages: [%{role: "user", content: prompt}]
           }),
         {:ok, result} <- SessionManager.execute_run(store, router, run.id, execute_opts) do
      {:ok, run, result}
    end
  end

  defp assert_capability_selection(result, preferred_provider) do
    routed_provider = get_in(result, [:routing, :routed_provider])

    if is_binary(routed_provider) and routed_provider != preferred_provider do
      :ok
    else
      {:error,
       Error.new(
         :internal_error,
         "capability routing did not move away from preferred provider: #{inspect(result.routing)}"
       )}
    end
  end

  defp assert_failover(result, preferred_provider) do
    failover_from = get_in(result, [:routing, :failover_from])
    failover_reason = get_in(result, [:routing, :failover_reason])
    routed_provider = get_in(result, [:routing, :routed_provider])

    cond do
      not is_binary(routed_provider) ->
        {:error, Error.new(:internal_error, "missing routed provider metadata")}

      routed_provider == preferred_provider ->
        {:error,
         Error.new(:internal_error, "failover did not occur; routed provider stayed preferred")}

      failover_from != preferred_provider ->
        {:error,
         Error.new(
           :internal_error,
           "failover metadata missing preferred provider as source: #{inspect(result.routing)}"
         )}

      failover_reason != :provider_unavailable ->
        {:error,
         Error.new(
           :internal_error,
           "unexpected failover reason: #{inspect(failover_reason)}"
         )}

      true ->
        :ok
    end
  end

  defp print_summary(capability_result, failover_result) do
    IO.puts("Capability-driven selection:")
    IO.puts("  routed_provider: #{capability_result.routing.routed_provider}")
    IO.puts("  attempt: #{capability_result.routing.routing_attempt}")
    IO.puts("  candidates: #{Enum.join(capability_result.routing.routing_candidates, ", ")}")

    IO.puts("\nRetryable failover:")
    IO.puts("  routed_provider: #{failover_result.routing.routed_provider}")
    IO.puts("  failover_from: #{failover_result.routing.failover_from}")
    IO.puts("  failover_reason: #{failover_result.routing.failover_reason}")
  end

  defp simulate_provider_outage(adapters, preferred_provider) do
    adapter = Map.fetch!(adapters, preferred_provider)

    if Process.alive?(adapter) do
      GenServer.stop(adapter, :normal)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp capability_requirement_for("claude"), do: %{type: :tool, name: "bash"}
  defp capability_requirement_for(_), do: %{type: :resource, name: "vision"}

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
    Usage: mix run examples/provider_routing.exs [options]

    Options:
      --provider, -p <name>  Preferred provider (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/provider_routing.exs --provider claude
      mix run examples/provider_routing.exs --provider codex
      mix run examples/provider_routing.exs --provider amp
    """)
  end
end

ProviderRoutingExample.main(System.argv())

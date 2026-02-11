defmodule CostTrackingExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Cost.CostCalculator
  alias AgentSessionManager.Policy.Policy
  alias AgentSessionManager.SessionManager

  @prompt "Reply in one short sentence about Elixir."
  @pricing_table CostCalculator.default_pricing_table()

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Cost Tracking Example (#{provider}) ===")
    IO.puts("")

    Application.put_env(:agent_session_manager, :pricing_table, @pricing_table)

    case run(provider) do
      :ok ->
        IO.puts("\nCost tracking example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nCost tracking example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, basic} <- run_basic_cost(store, adapter, provider),
         {:ok, budget} <- run_budget_demo(store, adapter, provider) do
      print_summary(basic, budget)
      :ok
    end
  end

  defp run_basic_cost(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "cost-example-#{provider}",
             context: %{system_prompt: "You are concise."},
             tags: ["example", "cost", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id),
         {:ok, run} <-
           SessionManager.start_run(store, adapter, session.id, %{
             messages: [%{role: "user", content: @prompt}]
           }),
         {:ok, result} <- SessionManager.execute_run(store, adapter, run.id) do
      model = find_run_model(result[:events] || [])

      calculated =
        case CostCalculator.calculate(result.token_usage || %{}, provider, model, @pricing_table) do
          {:ok, cost} -> cost
          {:error, _} -> nil
        end

      {:ok,
       %{
         provider: provider,
         model: model,
         token_usage: result.token_usage || %{},
         cost_usd: result[:cost_usd],
         calculated_cost_usd: calculated
       }}
    end
  end

  defp run_budget_demo(store, adapter, provider) do
    with {:ok, policy} <-
           Policy.new(
             name: "example-cost-budget",
             limits: [{:max_cost_usd, 0.0}],
             on_violation: :warn
           ),
         {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "cost-budget-#{provider}",
             context: %{system_prompt: "You are concise."},
             tags: ["example", "cost", "budget", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id),
         {:ok, run} <-
           SessionManager.start_run(store, adapter, session.id, %{
             messages: [%{role: "user", content: @prompt}]
           }),
         {:ok, result} <- SessionManager.execute_run(store, adapter, run.id, policy: policy) do
      violations = get_in(result, [:policy, :violations]) || []

      {:ok,
       %{
         policy_action: get_in(result, [:policy, :action]),
         policy_violations: length(violations),
         cost_usd: result[:cost_usd]
       }}
    end
  end

  defp print_summary(basic, budget) do
    IO.puts("Provider:     #{basic.provider}")
    IO.puts("Model:        #{basic.model || "unknown"}")
    IO.puts("Token usage:  #{inspect(basic.token_usage)}")
    IO.puts("Cost (USD):   $#{format_cost(basic.cost_usd)}")
    IO.puts("Calculated:   #{format_cost_or_na(basic.calculated_cost_usd)}")
    IO.puts("")
    IO.puts("Budget policy:")
    IO.puts("  action:     #{inspect(budget.policy_action)}")
    IO.puts("  violations: #{budget.policy_violations}")
    IO.puts("  cost:       $#{format_cost(budget.cost_usd)}")
  end

  defp find_run_model(events) when is_list(events) do
    Enum.find_value(events, fn
      %{type: :run_started, data: data} when is_map(data) ->
        data[:model] || data["model"]

      %{type: "run_started", data: data} when is_map(data) ->
        data[:model] || data["model"]

      %{"type" => :run_started, "data" => data} when is_map(data) ->
        data[:model] || data["model"]

      %{"type" => "run_started", "data" => data} when is_map(data) ->
        data[:model] || data["model"]

      _ ->
        nil
    end)
  end

  defp find_run_model(_), do: nil

  defp format_cost(nil), do: "N/A"

  defp format_cost(cost) when is_number(cost),
    do: :erlang.float_to_binary(cost * 1.0, decimals: 8)

  defp format_cost_or_na(nil), do: "N/A (no rates)"
  defp format_cost_or_na(cost) when is_number(cost), do: "$" <> format_cost(cost)

  defp start_adapter("claude"), do: ClaudeAdapter.start_link([])
  defp start_adapter("codex"), do: CodexAdapter.start_link(working_directory: File.cwd!())
  defp start_adapter("amp"), do: AmpAdapter.start_link(cwd: File.cwd!())
  defp start_adapter(provider), do: {:error, "unknown provider: #{provider}"}

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, help: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      IO.puts("""
      Usage: mix run examples/cost_tracking.exs [options]

      Options:
        --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
        --help, -h             Show this help message
      """)

      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      System.halt(1)
    end

    provider
  end
end

CostTrackingExample.main(System.argv())

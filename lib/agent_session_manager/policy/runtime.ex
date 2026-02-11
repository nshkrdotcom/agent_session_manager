defmodule AgentSessionManager.Policy.Runtime do
  @moduledoc """
  Mutable per-run policy state for real-time enforcement decisions.

  Runtime decisions can request either immediate cancellation (`cancel?`)
  or an approval signal (`request_approval?`) depending on policy action.
  """

  use GenServer

  alias AgentSessionManager.Policy.{Evaluator, Policy}

  @type decision :: %{
          violations: [Evaluator.violation()],
          cancel?: boolean(),
          request_approval?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec observe_event(GenServer.server(), map()) :: {:ok, decision()}
  def observe_event(server, event) when is_map(event) do
    GenServer.call(server, {:observe_event, event})
  end

  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl GenServer
  def init(opts) do
    case normalize_policy(Keyword.fetch!(opts, :policy)) do
      {:ok, policy} ->
        provider = Keyword.get(opts, :provider, "unknown")
        run_id = Keyword.get(opts, :run_id)

        cost_rates =
          Keyword.get(
            opts,
            :cost_rates,
            Application.get_env(:agent_session_manager, :policy_cost_rates, %{})
          )

        has_cost_limit = Enum.any?(policy.limits, &match?({:max_cost_usd, _}, &1))

        {:ok,
         %{
           policy: policy,
           provider: provider,
           run_id: run_id,
           started_monotonic_ms: now_ms(),
           elapsed_ms: 0,
           tool_calls: 0,
           input_tokens: 0,
           output_tokens: 0,
           total_tokens: 0,
           accumulated_cost_usd: 0.0,
           cost_supported?: not has_cost_limit,
           has_cost_limit: has_cost_limit,
           cost_rates: cost_rates,
           warnings: [],
           violations: [],
           cancel_requested?: false,
           approval_requested?: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:observe_event, event}, _from, state) do
    updated_state = update_runtime_state(state, event)

    runtime_snapshot = %{
      tool_calls: updated_state.tool_calls,
      total_tokens: updated_state.total_tokens,
      elapsed_ms: updated_state.elapsed_ms,
      accumulated_cost_usd: updated_state.accumulated_cost_usd,
      cost_supported?: updated_state.cost_supported?
    }

    violations =
      Evaluator.evaluate(
        updated_state.policy,
        runtime_snapshot,
        event,
        provider: updated_state.provider
      )

    cancel_now? =
      updated_state.policy.on_violation == :cancel and violations != [] and
        not updated_state.cancel_requested?

    request_approval? =
      updated_state.policy.on_violation == :request_approval and violations != [] and
        not updated_state.approval_requested?

    new_state = %{
      updated_state
      | violations: updated_state.violations ++ violations,
        cancel_requested?: updated_state.cancel_requested? or cancel_now?,
        approval_requested?: updated_state.approval_requested? or request_approval?
    }

    decision = %{
      violations: violations,
      cancel?: cancel_now?,
      request_approval?: request_approval?
    }

    {:reply, {:ok, decision}, new_state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      run_id: state.run_id,
      policy: state.policy,
      action: state.policy.on_violation,
      violated?: state.violations != [],
      violations: state.violations,
      cancel_requested?: state.cancel_requested?,
      approval_requested?: state.approval_requested?,
      usage: %{
        tool_calls: state.tool_calls,
        input_tokens: state.input_tokens,
        output_tokens: state.output_tokens,
        total_tokens: state.total_tokens,
        elapsed_ms: state.elapsed_ms,
        accumulated_cost_usd: state.accumulated_cost_usd
      },
      metadata: %{
        warnings: Enum.reverse(state.warnings),
        cost_supported?: state.cost_supported?
      }
    }

    {:reply, status, state}
  end

  defp normalize_policy(%Policy{} = policy), do: {:ok, policy}
  defp normalize_policy(policy_opts), do: Policy.new(policy_opts)

  defp update_runtime_state(state, event) do
    state
    |> update_elapsed_ms()
    |> maybe_increment_tool_calls(event)
    |> maybe_update_token_usage(event)
  end

  defp update_elapsed_ms(state) do
    %{state | elapsed_ms: max(now_ms() - state.started_monotonic_ms, 0)}
  end

  defp maybe_increment_tool_calls(state, %{type: :tool_call_started}) do
    %{state | tool_calls: state.tool_calls + 1}
  end

  defp maybe_increment_tool_calls(state, _event), do: state

  defp maybe_update_token_usage(state, %{type: :token_usage_updated, data: data})
       when is_map(data) do
    input_tokens = numeric_value(Map.get(data, :input_tokens))
    output_tokens = numeric_value(Map.get(data, :output_tokens))
    total_tokens = Map.get(data, :total_tokens)

    updated_input = state.input_tokens + input_tokens
    updated_output = state.output_tokens + output_tokens

    updated_total =
      if is_integer(total_tokens) and total_tokens >= 0 do
        max(state.total_tokens, total_tokens)
      else
        updated_input + updated_output
      end

    state
    |> maybe_update_cost(input_tokens, output_tokens)
    |> Map.put(:input_tokens, updated_input)
    |> Map.put(:output_tokens, updated_output)
    |> Map.put(:total_tokens, updated_total)
  end

  defp maybe_update_token_usage(state, _event), do: state

  defp maybe_update_cost(state, input_tokens, output_tokens) do
    case fetch_provider_rates(state.cost_rates, state.provider) do
      {:ok, %{input: input_rate, output: output_rate}} ->
        cost_delta = input_tokens * input_rate + output_tokens * output_rate

        %{
          state
          | accumulated_cost_usd: state.accumulated_cost_usd + cost_delta,
            cost_supported?: true
        }

      :error ->
        if state.has_cost_limit do
          warnings = add_warning(state.warnings, :missing_cost_rates)
          %{state | warnings: warnings, cost_supported?: false}
        else
          state
        end
    end
  end

  defp fetch_provider_rates(cost_rates, provider)
       when is_map(cost_rates) and is_binary(provider) do
    case Map.get(cost_rates, provider) do
      %{input: input_rate, output: output_rate}
      when is_number(input_rate) and is_number(output_rate) ->
        {:ok, %{input: input_rate * 1.0, output: output_rate * 1.0}}

      _ ->
        :error
    end
  end

  defp fetch_provider_rates(_cost_rates, _provider), do: :error

  defp add_warning(warnings, warning) do
    if warning in warnings do
      warnings
    else
      [warning | warnings]
    end
  end

  defp numeric_value(value) when is_integer(value) and value >= 0, do: value
  defp numeric_value(value) when is_float(value) and value >= 0, do: trunc(value)
  defp numeric_value(_), do: 0

  defp now_ms, do: System.monotonic_time(:millisecond)
end

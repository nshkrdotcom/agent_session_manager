defmodule ASM.Extensions.Policy do
  @moduledoc """
  Public policy extension API.

  This domain provides lightweight policy evaluation for tool governance
  and output budget limits with explicit violation actions.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      ASM.Extensions.Policy,
      ASM.Extensions.Policy.Enforcer,
      ASM.Extensions.Policy.Violation
    ]

  alias ASM.{Error, Event}
  alias ASM.Extensions.Policy.{Enforcer, Violation}

  @typedoc "Violation action taken when a policy rule is triggered."
  @type action :: Violation.action()

  @type t :: %__MODULE__{
          disallow_tools: MapSet.t(String.t()),
          max_output_tokens: non_neg_integer() | nil,
          on_tool_violation: action(),
          on_budget_violation: action()
        }

  @enforce_keys [:disallow_tools, :on_tool_violation, :on_budget_violation]
  defstruct disallow_tools: MapSet.new(),
            max_output_tokens: nil,
            on_tool_violation: :cancel,
            on_budget_violation: :cancel

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    tool_action = Keyword.get(opts, :on_tool_violation, Keyword.get(opts, :tool_action, :cancel))

    budget_action =
      Keyword.get(opts, :on_budget_violation, Keyword.get(opts, :budget_action, :cancel))

    with {:ok, disallow_tools} <-
           normalize_disallow_tools(Keyword.get(opts, :disallow_tools, [])),
         {:ok, max_output_tokens} <-
           normalize_max_output_tokens(Keyword.get(opts, :max_output_tokens)),
         {:ok, on_tool_violation} <- normalize_action(tool_action, :on_tool_violation),
         {:ok, on_budget_violation} <- normalize_action(budget_action, :on_budget_violation) do
      {:ok,
       %__MODULE__{
         disallow_tools: disallow_tools,
         max_output_tokens: max_output_tokens,
         on_tool_violation: on_tool_violation,
         on_budget_violation: on_budget_violation
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) when is_list(opts) do
    case new(opts) do
      {:ok, policy} ->
        policy

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec enforcer_plug(t(), keyword()) :: {module(), keyword()}
  def enforcer_plug(%__MODULE__{} = policy, opts \\ []) when is_list(opts) do
    {Enforcer, Keyword.put(opts, :policy, policy)}
  end

  @doc """
  Pure policy evaluation.

  Returns:
  - `{:ok, next_ctx}` when no rule is violated
  - `{:violation, violation, next_ctx}` when a rule is violated
  """
  @spec evaluate(t(), Event.t(), map()) ::
          {:ok, map()} | {:violation, Violation.t(), map()}
  def evaluate(%__MODULE__{} = policy, %Event{} = event, ctx) when is_map(ctx) do
    with {:ok, ctx} <- evaluate_tool_rule(policy, event, ctx),
         {:ok, ctx} <- evaluate_budget_rule(policy, event, ctx) do
      {:ok, ctx}
    else
      {:violation, violation, next_ctx} ->
        {:violation, violation, next_ctx}
    end
  end

  defp evaluate_tool_rule(
         %__MODULE__{disallow_tools: disallow_tools, on_tool_violation: action},
         %Event{kind: :tool_use} = event,
         ctx
       ) do
    payload = Event.legacy_payload(event)

    if MapSet.member?(disallow_tools, payload.tool_name) do
      violation =
        Violation.new(
          :tool_disallowed,
          action,
          "Tool blocked by policy: #{payload.tool_name}",
          direction: :input,
          metadata: %{
            tool_name: payload.tool_name,
            tool_id: payload.tool_id,
            tool_input: payload.input
          }
        )

      {:violation, violation, ctx}
    else
      {:ok, ctx}
    end
  end

  defp evaluate_tool_rule(_policy, _event, ctx), do: {:ok, ctx}

  defp evaluate_budget_rule(%__MODULE__{max_output_tokens: nil}, _event, ctx), do: {:ok, ctx}

  defp evaluate_budget_rule(
         %__MODULE__{max_output_tokens: max_output_tokens, on_budget_violation: action},
         %Event{kind: :result} = event,
         ctx
       ) do
    payload = Event.legacy_payload(event)
    output_tokens = extract_output_tokens(payload.usage)
    current_total = default_zero(get_in(ctx, [:policy, :output_tokens]))
    next_total = current_total + output_tokens

    next_ctx =
      put_in(ctx, [Access.key(:policy, %{}), Access.key(:output_tokens)], next_total)

    if next_total > max_output_tokens do
      violation =
        Violation.new(
          :output_budget_exceeded,
          action,
          "Output tokens exceeded policy limit",
          direction: :output,
          metadata: %{
            output_tokens: output_tokens,
            total_output_tokens: next_total,
            max_output_tokens: max_output_tokens
          }
        )

      {:violation, violation, next_ctx}
    else
      {:ok, next_ctx}
    end
  end

  defp evaluate_budget_rule(_policy, _event, ctx), do: {:ok, ctx}

  defp normalize_disallow_tools(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      tool_name, {:ok, acc} when is_binary(tool_name) and tool_name != "" ->
        {:cont, {:ok, MapSet.put(acc, tool_name)}}

      tool_name, {:ok, acc} when is_atom(tool_name) ->
        {:cont, {:ok, MapSet.put(acc, Atom.to_string(tool_name))}}

      invalid, _acc ->
        {:halt,
         {:error,
          config_error(
            ":disallow_tools entries must be non-empty strings or atoms, got: #{inspect(invalid)}"
          )}}
    end)
  end

  defp normalize_disallow_tools(other) do
    {:error, config_error(":disallow_tools must be a list, got: #{inspect(other)}")}
  end

  defp normalize_max_output_tokens(nil), do: {:ok, nil}

  defp normalize_max_output_tokens(value) when is_integer(value) and value >= 0 do
    {:ok, value}
  end

  defp normalize_max_output_tokens(other) do
    {:error,
     config_error(":max_output_tokens must be a non-negative integer, got: #{inspect(other)}")}
  end

  defp normalize_action(action, _field) when action in [:warn, :request_approval, :cancel] do
    {:ok, action}
  end

  defp normalize_action(other, field) do
    {:error,
     config_error("#{field} must be :warn, :request_approval, or :cancel, got: #{inspect(other)}")}
  end

  defp extract_output_tokens(usage) when is_map(usage) do
    Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
  end

  defp extract_output_tokens(_), do: 0

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end

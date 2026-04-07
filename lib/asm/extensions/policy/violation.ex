defmodule ASM.Extensions.Policy.Violation do
  @moduledoc """
  Normalized policy-violation descriptor with explicit action semantics.
  """

  alias ASM.{Control, Error, Event}

  @typedoc "Violation action."
  @type action :: :warn | :request_approval | :cancel

  @typedoc "Policy direction where the rule was evaluated."
  @type direction :: :input | :output

  @type t :: %__MODULE__{
          rule: atom() | String.t(),
          action: action(),
          direction: direction(),
          message: String.t(),
          metadata: map()
        }

  @enforce_keys [:rule, :action, :direction, :message]
  defstruct [:rule, :action, :direction, :message, metadata: %{}]

  @spec new(atom() | String.t(), action(), String.t(), keyword()) :: t()
  def new(rule, action, message, opts \\ [])
      when (is_atom(rule) or is_binary(rule)) and
             action in [:warn, :request_approval, :cancel] and
             is_binary(message) do
    %__MODULE__{
      rule: rule,
      action: action,
      direction: Keyword.get(opts, :direction, :input),
      message: message,
      metadata: normalize_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec to_guardrail_trigger(t()) :: Control.GuardrailTrigger.t()
  def to_guardrail_trigger(%__MODULE__{} = violation) do
    %Control.GuardrailTrigger{
      rule: normalize_rule(violation.rule),
      direction: violation.direction,
      action: violation.action
    }
  end

  @spec to_error(t(), Event.t()) :: Error.t()
  def to_error(%__MODULE__{} = violation, %Event{} = source_event) do
    Error.new(:guardrail_blocked, :guardrail, violation.message,
      cause: %{
        rule: normalize_rule(violation.rule),
        action: violation.action,
        direction: violation.direction,
        metadata: violation.metadata,
        event_id: source_event.id,
        event_kind: source_event.kind
      }
    )
  end

  defp normalize_rule(rule) when is_atom(rule), do: Atom.to_string(rule)
  defp normalize_rule(rule) when is_binary(rule), do: rule

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_other), do: %{}
end

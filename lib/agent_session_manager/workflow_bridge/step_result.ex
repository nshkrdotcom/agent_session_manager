defmodule AgentSessionManager.WorkflowBridge.StepResult do
  @moduledoc """
  Normalized result from a workflow step execution.

  Provides a consistent data shape regardless of whether the step used
  `run_once/4` (one-shot) or `execute_run/4` (multi-run). Includes
  routing signals that workflow engines can use for branching decisions.
  """

  @type t :: %__MODULE__{
          output: map(),
          content: String.t() | nil,
          token_usage: map(),
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          events: [map()],
          stop_reason: String.t() | nil,
          tool_calls: [map()],
          has_tool_calls: boolean(),
          persistence_failures: non_neg_integer(),
          workspace: map() | nil,
          policy: map() | nil,
          retryable: boolean()
        }

  defstruct [
    :output,
    :content,
    :session_id,
    :run_id,
    :stop_reason,
    :workspace,
    :policy,
    token_usage: %{},
    events: [],
    tool_calls: [],
    has_tool_calls: false,
    persistence_failures: 0,
    retryable: false
  ]
end

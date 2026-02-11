defmodule AgentSessionManager.WorkflowBridge.ErrorClassification do
  @moduledoc """
  Classification of an ASM error for workflow routing decisions.
  """

  @type recommended_action :: :retry | :failover | :abort | :wait_and_retry | :cancel

  @type t :: %__MODULE__{
          error: AgentSessionManager.Core.Error.t(),
          retryable: boolean(),
          category: atom(),
          recommended_action: recommended_action()
        }

  defstruct [:error, :category, :recommended_action, retryable: false]
end

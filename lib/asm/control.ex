defmodule ASM.Control do
  @moduledoc """
  Control-layer payload variants.
  """

  defmodule ApprovalRequest do
    @moduledoc """
    Tool approval prompt emitted when the provider requires operator input.
    """
    @enforce_keys [:approval_id, :tool_name, :tool_input]
    defstruct [:approval_id, :tool_name, :tool_input]

    @type t :: %__MODULE__{approval_id: String.t(), tool_name: String.t(), tool_input: map()}
  end

  defmodule ApprovalResolution do
    @moduledoc """
    Approval decision sent back to resume or block a tool call.
    """
    @enforce_keys [:approval_id, :decision]
    defstruct [:approval_id, :decision, :reason]

    @type decision :: :allow | :deny
    @type t :: %__MODULE__{
            approval_id: String.t(),
            decision: decision(),
            reason: String.t() | nil
          }
  end

  defmodule GuardrailTrigger do
    @moduledoc """
    Signal that a policy/guardrail rule was triggered.
    """
    @enforce_keys [:rule, :direction, :action]
    defstruct [:rule, :direction, :action]

    @type direction :: :input | :output
    @type action :: :block | :warn | :request_approval | :cancel
    @type t :: %__MODULE__{rule: String.t(), direction: direction(), action: action()}
  end

  defmodule CostUpdate do
    @moduledoc """
    Incremental token and cost accounting update.
    """
    @enforce_keys [:input_tokens, :output_tokens, :cost_usd]
    defstruct [:input_tokens, :output_tokens, :cost_usd]

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cost_usd: float()
          }
  end

  defmodule RunLifecycle do
    @moduledoc """
    Run lifecycle checkpoint emitted by the runtime.
    """
    @enforce_keys [:status, :summary]
    defstruct [:status, :summary]

    @type status :: :started | :completed | :failed
    @type t :: %__MODULE__{status: status(), summary: map()}
  end

  defmodule Raw do
    @moduledoc """
    Provider-native control event preserved in normalized form.
    """
    @enforce_keys [:provider, :type, :data]
    defstruct [:provider, :type, :data]

    @type t :: %__MODULE__{provider: atom(), type: String.t(), data: map()}
  end

  @type t ::
          ApprovalRequest.t()
          | ApprovalResolution.t()
          | GuardrailTrigger.t()
          | CostUpdate.t()
          | RunLifecycle.t()
          | Raw.t()
end

defmodule ASM.Control do
  @moduledoc """
  Control-layer payload variants.
  """

  defmodule TransportStatus do
    @moduledoc false
    @enforce_keys [:status, :transport_pid]
    defstruct [:status, :transport_pid]

    @type status :: :opened | :closed
    @type t :: %__MODULE__{status: status(), transport_pid: pid()}
  end

  defmodule ApprovalRequest do
    @moduledoc false
    @enforce_keys [:approval_id, :tool_name, :tool_input]
    defstruct [:approval_id, :tool_name, :tool_input]

    @type t :: %__MODULE__{approval_id: String.t(), tool_name: String.t(), tool_input: map()}
  end

  defmodule ApprovalResolution do
    @moduledoc false
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
    @moduledoc false
    @enforce_keys [:rule, :direction, :action]
    defstruct [:rule, :direction, :action]

    @type direction :: :input | :output
    @type action :: :block | :warn
    @type t :: %__MODULE__{rule: String.t(), direction: direction(), action: action()}
  end

  defmodule CostUpdate do
    @moduledoc false
    @enforce_keys [:input_tokens, :output_tokens, :cost_usd]
    defstruct [:input_tokens, :output_tokens, :cost_usd]

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cost_usd: float()
          }
  end

  defmodule RunLifecycle do
    @moduledoc false
    @enforce_keys [:status, :summary]
    defstruct [:status, :summary]

    @type status :: :started | :completed | :failed
    @type t :: %__MODULE__{status: status(), summary: map()}
  end

  defmodule Backpressure do
    @moduledoc false
    @enforce_keys [:queue_size, :policy, :run_id]
    defstruct [:queue_size, :policy, :run_id]

    @type policy :: :drop_oldest | :fail_run | :block
    @type t :: %__MODULE__{queue_size: non_neg_integer(), policy: policy(), run_id: String.t()}
  end

  defmodule Raw do
    @moduledoc false
    @enforce_keys [:provider, :type, :data]
    defstruct [:provider, :type, :data]

    @type t :: %__MODULE__{provider: atom(), type: String.t(), data: map()}
  end

  @type t ::
          TransportStatus.t()
          | ApprovalRequest.t()
          | ApprovalResolution.t()
          | GuardrailTrigger.t()
          | CostUpdate.t()
          | RunLifecycle.t()
          | Backpressure.t()
          | Raw.t()
end

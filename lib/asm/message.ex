defmodule ASM.Message do
  @moduledoc """
  Conversation-layer payload variants.
  """

  alias ASM.Content

  defmodule Assistant do
    @moduledoc """
    Assistant-authored message composed of one or more content blocks.
    """
    @enforce_keys [:content]
    defstruct [:content, :model, metadata: %{}]

    @type t :: %__MODULE__{content: [Content.t()], model: String.t() | nil, metadata: map()}
  end

  defmodule User do
    @moduledoc """
    User-authored message composed of one or more content blocks.
    """
    @enforce_keys [:content]
    defstruct [:content]

    @type t :: %__MODULE__{content: [Content.t()]}
  end

  defmodule ToolUse do
    @moduledoc """
    Request from the model to execute a tool.
    """
    @enforce_keys [:tool_name, :tool_id, :input]
    defstruct [:tool_name, :tool_id, :input]

    @type t :: %__MODULE__{tool_name: String.t(), tool_id: String.t(), input: map()}
  end

  defmodule ToolResult do
    @moduledoc """
    Result returned to the model for a previously requested tool call.
    """
    @enforce_keys [:tool_id, :content]
    defstruct [:tool_id, :content, is_error: false]

    @type t :: %__MODULE__{tool_id: String.t(), content: term(), is_error: boolean()}
  end

  defmodule Result do
    @moduledoc """
    Terminal metadata describing why a run completed.
    """
    @enforce_keys [:stop_reason]
    defstruct [:stop_reason, usage: %{}, duration_ms: nil, metadata: %{}]

    @type t :: %__MODULE__{
            stop_reason: atom() | String.t(),
            usage: map(),
            duration_ms: non_neg_integer() | nil,
            metadata: map()
          }
  end

  defmodule Partial do
    @moduledoc """
    Incremental text or thinking delta emitted during streaming.
    """
    @enforce_keys [:content_type, :delta]
    defstruct [:content_type, :delta]

    @type content_type :: :text | :thinking
    @type t :: %__MODULE__{content_type: content_type(), delta: String.t()}
  end

  defmodule Error do
    @moduledoc """
    Structured error message emitted by the provider/runtime.
    """
    @enforce_keys [:severity, :message, :kind]
    defstruct [:severity, :message, :kind]

    @type severity :: :fatal | :error | :warning
    @type t :: %__MODULE__{severity: severity(), message: String.t(), kind: atom()}
  end

  defmodule System do
    @moduledoc """
    System-level initialization payloads.
    """
    @enforce_keys [:init_data]
    defstruct [:init_data]

    @type t :: %__MODULE__{init_data: map()}
  end

  defmodule Thinking do
    @moduledoc """
    Provider thinking payload emitted as a top-level message.
    """
    @enforce_keys [:thinking]
    defstruct [:thinking, :signature]

    @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
  end

  defmodule Raw do
    @moduledoc """
    Provider-native message event preserved in normalized form.
    """
    @enforce_keys [:provider, :type, :data]
    defstruct [:provider, :type, :data]

    @type t :: %__MODULE__{provider: atom(), type: String.t(), data: map()}
  end

  @type t ::
          Assistant.t()
          | User.t()
          | ToolUse.t()
          | ToolResult.t()
          | Result.t()
          | Partial.t()
          | Error.t()
          | System.t()
          | Thinking.t()
          | Raw.t()
end

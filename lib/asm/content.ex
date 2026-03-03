defmodule ASM.Content do
  @moduledoc """
  Content block variants shared across messages.
  """

  defmodule Text do
    @moduledoc false
    @enforce_keys [:text]
    defstruct [:text]

    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule Thinking do
    @moduledoc false
    @enforce_keys [:thinking]
    defstruct [:thinking, :signature]

    @type t :: %__MODULE__{thinking: String.t(), signature: String.t() | nil}
  end

  defmodule ToolUse do
    @moduledoc false
    @enforce_keys [:tool_name, :tool_id, :input]
    defstruct [:tool_name, :tool_id, :input]

    @type t :: %__MODULE__{tool_name: String.t(), tool_id: String.t(), input: map()}
  end

  defmodule ToolResult do
    @moduledoc false
    @enforce_keys [:tool_id, :content]
    defstruct [:tool_id, :content, is_error: false]

    @type t :: %__MODULE__{tool_id: String.t(), content: term(), is_error: boolean()}
  end

  @type t :: Text.t() | Thinking.t() | ToolUse.t() | ToolResult.t()
end

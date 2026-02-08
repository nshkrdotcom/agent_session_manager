defmodule AgentSessionManager.Core.Transcript do
  @moduledoc """
  Provider-agnostic transcript reconstructed from persisted session events.
  """

  @type role :: :system | :user | :assistant | :tool

  @type message :: %{
          role: role(),
          content: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          tool_input: map() | nil,
          tool_output: map() | String.t() | nil,
          metadata: map()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          messages: [message()],
          last_sequence: non_neg_integer() | nil,
          last_timestamp: DateTime.t() | nil,
          metadata: map()
        }

  @enforce_keys [:session_id]
  defstruct [:session_id, :last_sequence, :last_timestamp, messages: [], metadata: %{}]

  @spec new(String.t(), keyword()) :: t()
  def new(session_id, opts \\ []) when is_binary(session_id) and session_id != "" do
    %__MODULE__{
      session_id: session_id,
      messages: Keyword.get(opts, :messages, []),
      last_sequence: Keyword.get(opts, :last_sequence),
      last_timestamp: Keyword.get(opts, :last_timestamp),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

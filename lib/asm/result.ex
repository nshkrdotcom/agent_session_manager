defmodule ASM.Result do
  @moduledoc """
  Final run projection returned by `ASM.query/3`.

  Result metadata is derived from the run event stream so streaming consumers
  and query-style consumers observe the same lane/backend/execution metadata.

  `:object` is the provider-returned structured object for a run that requested
  one through `:output_schema`. It is `nil` whenever the provider returned no
  structured object; nothing here reconstructs or guesses an object from prose.
  """

  @enforce_keys [:run_id, :session_id]
  defstruct [
    :run_id,
    :session_id,
    :text,
    :object,
    :messages,
    :cost,
    :error,
    :duration_ms,
    :stop_reason,
    :session_id_from_cli,
    :metadata
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          session_id: String.t(),
          text: String.t() | nil,
          object: term() | nil,
          messages: list() | nil,
          cost: map() | nil,
          error: ASM.Error.t() | nil,
          duration_ms: non_neg_integer() | nil,
          stop_reason: atom() | String.t() | nil,
          session_id_from_cli: String.t() | nil,
          metadata: map() | nil
        }
end

defmodule ASM.Event do
  @moduledoc """
  Event envelope for all normalized ASM runtime events.
  """

  import Bitwise

  alias ASM.{Control, Message}

  @enforce_keys [:id, :kind, :run_id, :session_id, :timestamp]
  defstruct [
    :id,
    :kind,
    :run_id,
    :session_id,
    :provider,
    :payload,
    :sequence,
    :timestamp,
    :correlation_id,
    :causation_id
  ]

  @type kind ::
          :assistant_message
          | :assistant_delta
          | :user_message
          | :tool_use
          | :tool_result
          | :thinking
          | :result
          | :error
          | :system
          | :transport_opened
          | :transport_closed
          | :approval_requested
          | :approval_resolved
          | :guardrail_triggered
          | :cost_update
          | :run_started
          | :run_completed
          | :backpressure
          | :raw

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          run_id: String.t(),
          session_id: String.t(),
          provider: atom() | nil,
          payload: Message.t() | Control.t() | nil,
          sequence: non_neg_integer() | nil,
          timestamp: DateTime.t(),
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil
        }

  @crockford ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @ulid_chars 26
  @max_timestamp 281_474_976_710_655

  @spec generate_id() :: String.t()
  def generate_id do
    generate_id_at(System.system_time(:millisecond))
  end

  @spec generate_id_at(non_neg_integer()) :: String.t()
  def generate_id_at(timestamp_ms) when is_integer(timestamp_ms) and timestamp_ms >= 0 do
    if timestamp_ms > @max_timestamp do
      raise ArgumentError, "timestamp out of ULID range: #{timestamp_ms}"
    end

    random = :crypto.strong_rand_bytes(10)
    random_int = :binary.decode_unsigned(random)
    ulid_int = (timestamp_ms <<< 80) + random_int

    encode_crockford(ulid_int, @ulid_chars)
  end

  def generate_id_at(other) do
    raise ArgumentError, "timestamp must be a non-negative integer, got: #{inspect(other)}"
  end

  defp encode_crockford(value, width) do
    digits = do_encode(value, [])

    digits
    |> left_pad(width, ?0)
    |> to_string()
  end

  defp do_encode(0, []), do: [?0]
  defp do_encode(0, acc), do: acc

  defp do_encode(value, acc) do
    rem_index = rem(value, 32)
    next = div(value, 32)
    char = Enum.at(@crockford, rem_index)
    do_encode(next, [char | acc])
  end

  defp left_pad(chars, width, pad_char) do
    missing = max(width - length(chars), 0)
    List.duplicate(pad_char, missing) ++ chars
  end
end

defmodule ASM.Extensions.PubSub.Payload do
  @moduledoc """
  Canonical payload contract for PubSub broadcast events.

  Payload shape (`asm.pubsub.event.v1`):

      %{
        schema: "asm.pubsub.event.v1",
        event: %ASM.Event{},
        meta: %{
          event_id: String.t(),
          event_kind: atom(),
          session_id: String.t(),
          run_id: String.t(),
          provider: atom() | nil,
          published_at: DateTime.t(),
          source: atom(),
          topics: [String.t()]
        }
      }
  """

  alias ASM.Event

  @schema "asm.pubsub.event.v1"

  @type meta :: %{
          required(:event_id) => String.t(),
          required(:event_kind) => Event.kind(),
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:provider) => atom() | nil,
          required(:published_at) => DateTime.t(),
          required(:source) => atom(),
          optional(:topics) => [String.t()]
        }

  @type t :: %{
          required(:schema) => String.t(),
          required(:event) => Event.t(),
          required(:meta) => meta()
        }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec build(Event.t(), keyword()) :: t()
  def build(%Event{} = event, opts \\ []) when is_list(opts) do
    topics = Keyword.get(opts, :topics, [])

    %{
      schema: @schema,
      event: event,
      meta: %{
        event_id: event.id,
        event_kind: event.kind,
        session_id: event.session_id,
        run_id: event.run_id,
        provider: event.provider,
        published_at: DateTime.utc_now(),
        source: Keyword.get(opts, :source, :pipeline),
        topics: List.wrap(topics)
      }
    }
  end
end

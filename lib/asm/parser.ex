defmodule ASM.Parser do
  @moduledoc """
  Behaviour for provider event parsers.
  """

  @type raw_event :: map()
  @type parsed_event_kind :: ASM.Event.kind()
  @type parsed_payload :: ASM.Message.t() | ASM.Control.t()

  @callback parse(raw_event()) ::
              {:ok, {parsed_event_kind(), parsed_payload()}} | {:error, term()}
end

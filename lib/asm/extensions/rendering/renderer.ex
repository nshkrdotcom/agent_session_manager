defmodule ASM.Extensions.Rendering.Renderer do
  @moduledoc """
  Behaviour for rendering `%ASM.Event{}` values into display iodata.
  """

  alias ASM.{Error, Event}

  @type state :: term()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state()} | {:error, Error.t() | term()}

  @callback render_event(Event.t(), state()) ::
              {:ok, iodata(), state()} | {:error, Error.t() | term()}

  @callback finish(state()) :: {:ok, iodata(), state()} | {:error, Error.t() | term()}
end

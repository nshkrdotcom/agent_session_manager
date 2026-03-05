defmodule ASM.Extensions.Rendering.Sink do
  @moduledoc """
  Behaviour for sink destinations that receive rendered iodata and events.
  """

  alias ASM.{Error, Event}

  @type state :: term()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state()} | {:error, Error.t() | term()}

  @callback write(iodata(), state()) ::
              {:ok, state()}
              | {:error, Error.t() | term()}
              | {:error, Error.t() | term(), state()}

  @callback write_event(Event.t(), iodata(), state()) ::
              {:ok, state()}
              | {:error, Error.t() | term()}
              | {:error, Error.t() | term(), state()}

  @callback flush(state()) ::
              {:ok, state()}
              | {:error, Error.t() | term()}
              | {:error, Error.t() | term(), state()}

  @callback close(state()) :: :ok | {:error, Error.t() | term()}
end

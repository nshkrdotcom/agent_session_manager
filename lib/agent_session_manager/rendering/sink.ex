defmodule AgentSessionManager.Rendering.Sink do
  @moduledoc """
  Behaviour for output destinations that receive rendered text from a renderer.

  A sink writes rendered output to a specific destination: terminal, file, JSON log,
  callback function, etc. Sinks receive iodata and decide how to write it.

  ## Implementing a Sink

      defmodule MySink do
        @behaviour AgentSessionManager.Rendering.Sink

        @impl true
        def init(opts), do: {:ok, %{device: opts[:device] || :stdio}}

        @impl true
        def write(iodata, state) do
          IO.write(state.device, iodata)
          {:ok, state}
        end

        @impl true
        def write_event(_event, _iodata, state), do: {:ok, state}

        @impl true
        def flush(state), do: {:ok, state}

        @impl true
        def close(state), do: :ok
      end

  ## Rendered vs Raw Output

  Sinks receive output through two channels:

  - `write/2` — Rendered text from the renderer. Used for human-readable output.
  - `write_event/3` — The raw event plus rendered text. Used by sinks that need
    the structured event data (e.g. JSONL loggers that serialize events, not text).
  """

  @type state :: term()
  @type opts :: keyword()

  @doc """
  Initialize sink state from options.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, term()}

  @doc """
  Write rendered iodata to the output destination.
  """
  @callback write(iodata(), state()) :: {:ok, state()} | {:error, term(), state()}

  @doc """
  Write the raw event alongside its rendered form. Called for every event.

  Sinks that only care about rendered text can delegate to `write/2` or no-op.
  Sinks that need structured data (JSONL, callback) use the event directly.
  """
  @callback write_event(event :: map(), iodata(), state()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc """
  Flush any buffered output.
  """
  @callback flush(state()) :: {:ok, state()}

  @doc """
  Close the sink and release resources.
  """
  @callback close(state()) :: :ok
end

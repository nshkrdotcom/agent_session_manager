defmodule AgentSessionManager.Ports.DurableStore do
  @moduledoc """
  Boundary-oriented persistence port for execution results.
  """

  alias AgentSessionManager.Core.{Error, Event, Run, Session}

  @type store :: module() | GenServer.server()
  @type run_id :: String.t()
  @type session_id :: String.t()
  @type execution_result :: %{
          session: Session.t(),
          run: Run.t(),
          events: [Event.t()],
          provider_metadata: map()
        }

  @callback flush(store(), execution_result()) :: :ok | {:error, Error.t()}
  @callback load_run(store(), run_id()) :: {:ok, Run.t()} | {:error, Error.t()}
  @callback load_session(store(), session_id()) :: {:ok, Session.t()} | {:error, Error.t()}
  @callback load_events(store(), session_id(), keyword()) ::
              {:ok, [Event.t()]} | {:error, Error.t()}
end

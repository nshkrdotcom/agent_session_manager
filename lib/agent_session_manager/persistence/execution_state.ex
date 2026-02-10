defmodule AgentSessionManager.Persistence.ExecutionState do
  @moduledoc """
  In-memory execution state used while a run is in progress.
  """

  alias AgentSessionManager.Core.{Event, Run, Session}

  @type t :: %__MODULE__{
          session: Session.t(),
          run: Run.t(),
          events: [Event.t()],
          provider_metadata: map(),
          sequence_counter: non_neg_integer()
        }

  @type execution_result :: %{
          session: Session.t(),
          run: Run.t(),
          events: [Event.t()],
          provider_metadata: map()
        }

  defstruct [
    :session,
    :run,
    events: [],
    provider_metadata: %{},
    sequence_counter: 0
  ]

  @spec new(Session.t(), Run.t()) :: t()
  def new(%Session{} = session, %Run{} = run) do
    %__MODULE__{session: session, run: run}
  end

  @spec append_event(t(), Event.t()) :: t()
  def append_event(%__MODULE__{} = state, %Event{} = event) do
    next_sequence = state.sequence_counter + 1

    %{
      state
      | events: [event | state.events],
        sequence_counter: next_sequence
    }
  end

  @spec cache_provider_metadata(t(), map()) :: t()
  def cache_provider_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | provider_metadata: Map.merge(state.provider_metadata, metadata)}
  end

  @spec update_session(t(), (Session.t() -> Session.t())) :: t()
  def update_session(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    %{state | session: fun.(state.session)}
  end

  @spec update_run(t(), (Run.t() -> Run.t())) :: t()
  def update_run(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    %{state | run: fun.(state.run)}
  end

  @spec finalized_events(t()) :: [Event.t()]
  def finalized_events(%__MODULE__{} = state) do
    Enum.reverse(state.events)
  end

  @spec to_result(t()) :: execution_result()
  def to_result(%__MODULE__{} = state) do
    %{
      session: state.session,
      run: state.run,
      events: finalized_events(state),
      provider_metadata: state.provider_metadata
    }
  end
end

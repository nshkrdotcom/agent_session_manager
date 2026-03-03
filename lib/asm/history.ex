defmodule ASM.History do
  @moduledoc """
  Replay and rebuild helpers on top of `ASM.Store`.
  """

  alias ASM.{Error, Run, Store}

  @spec replay_session(pid(), String.t(), term(), (term(), ASM.Event.t() -> term())) ::
          {:ok, term()} | {:error, Error.t()}
  def replay_session(store, session_id, initial_state, reducer)
      when is_binary(session_id) and is_function(reducer, 2) do
    with {:ok, events} <- Store.list_events(store, session_id) do
      {:ok, Enum.reduce(events, initial_state, fn event, acc -> reducer.(acc, event) end)}
    end
  end

  @spec rebuild_run(pid(), String.t(), String.t()) ::
          {:ok, %{state: Run.State.t(), result: ASM.Result.t(), events: [ASM.Event.t()]}}
          | {:error, Error.t()}
  def rebuild_run(store, session_id, run_id) when is_binary(session_id) and is_binary(run_id) do
    with {:ok, events} <- Store.list_events(store, session_id) do
      run_events = Enum.filter(events, fn event -> event.run_id == run_id end)

      case run_events do
        [] ->
          {:error, Error.new(:unknown, :runtime, "Run not found in session history")}

        [first | _] ->
          state =
            Run.State.new(
              run_id: run_id,
              session_id: session_id,
              provider: first.provider || :unknown
            )

          rebuilt_state = Enum.reduce(run_events, state, &Run.EventReducer.apply_event!(&2, &1))

          {:ok,
           %{
             state: rebuilt_state,
             result: Run.EventReducer.to_result(rebuilt_state),
             events: run_events
           }}
      end
    end
  end
end

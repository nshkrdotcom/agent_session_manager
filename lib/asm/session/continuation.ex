defmodule ASM.Session.Continuation do
  @moduledoc """
  Session checkpoint helpers for capture and restore seams.
  """

  alias ASM.Session.State

  @type checkpoint :: %{
          required(:session_id) => String.t(),
          required(:provider) => atom(),
          required(:captured_at) => DateTime.t(),
          optional(:run_id) => String.t(),
          optional(:provider_session_id) => String.t(),
          optional(:cost) => map(),
          optional(:metadata) => map()
        }

  @spec capture(State.t(), map()) :: checkpoint()
  def capture(%State{} = state, attrs \\ %{}) when is_map(attrs) do
    %{
      session_id: state.session_id,
      provider: state.provider.name,
      captured_at: DateTime.utc_now(),
      run_id: Map.get(attrs, :run_id),
      provider_session_id: Map.get(attrs, :provider_session_id),
      cost: state.cost,
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec restore(State.t(), checkpoint()) :: State.t()
  def restore(%State{} = state, checkpoint) when is_map(checkpoint) do
    %{state | checkpoint: checkpoint}
  end
end

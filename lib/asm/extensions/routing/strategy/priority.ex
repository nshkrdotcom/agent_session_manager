defmodule ASM.Extensions.Routing.Strategy.Priority do
  @moduledoc """
  Stable priority strategy that always picks the lowest priority value.
  """

  @behaviour ASM.Extensions.Routing.Strategy

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def choose([], _state, _opts), do: :none

  def choose(candidates, state, _opts) do
    candidate = Enum.min_by(candidates, &{&1.priority, &1.position})
    {:ok, candidate, state}
  end
end

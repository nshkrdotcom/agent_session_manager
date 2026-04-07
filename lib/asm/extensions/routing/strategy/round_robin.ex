defmodule ASM.Extensions.Routing.Strategy.RoundRobin do
  @moduledoc """
  Deterministic round-robin strategy.
  """

  @behaviour ASM.Extensions.Routing.Strategy

  @impl true
  def init(_opts), do: {:ok, 0}

  @impl true
  def choose([], _state, _opts), do: :none

  def choose(candidates, state, _opts) when is_list(candidates) and is_integer(state) do
    index = Integer.mod(state, length(candidates))
    candidate = Enum.at(candidates, index)
    {:ok, candidate, state + 1}
  end
end

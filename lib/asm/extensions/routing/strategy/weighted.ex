defmodule ASM.Extensions.Routing.Strategy.Weighted do
  @moduledoc """
  Deterministic weighted round-robin strategy.
  """

  @behaviour ASM.Extensions.Routing.Strategy

  @impl true
  def init(_opts), do: {:ok, 0}

  @impl true
  def choose([], _state, _opts), do: :none

  def choose(candidates, state, _opts) when is_integer(state) do
    weighted = weighted_candidates(candidates)
    index = Integer.mod(state, length(weighted))
    candidate = Enum.at(weighted, index)
    {:ok, candidate, state + 1}
  end

  defp weighted_candidates(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      List.duplicate(candidate, max(candidate.weight, 1))
    end)
  end
end

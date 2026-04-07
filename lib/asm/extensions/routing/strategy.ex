defmodule ASM.Extensions.Routing.Strategy do
  @moduledoc """
  Selection strategy contract for routing provider candidates.
  """

  alias ASM.Error

  @typedoc "Router candidate metadata presented to strategies."
  @type candidate :: %{
          required(:id) => term(),
          required(:provider) => atom(),
          required(:provider_opts) => keyword(),
          required(:priority) => integer(),
          required(:weight) => pos_integer(),
          required(:position) => non_neg_integer()
        }

  @typedoc "Opaque strategy state."
  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, Error.t()}
  @callback choose([candidate()], state(), keyword()) ::
              {:ok, candidate(), state()} | :none | {:error, Error.t()}
end

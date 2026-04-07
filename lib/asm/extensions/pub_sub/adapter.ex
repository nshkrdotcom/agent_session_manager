defmodule ASM.Extensions.PubSub.Adapter do
  @moduledoc """
  Behaviour for PubSub adapter implementations.

  Adapters encapsulate subscription and broadcast mechanics for a concrete
  backend (for example local `Registry` or Phoenix PubSub).
  """

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, ASM.Error.t() | term()}

  @callback broadcast(state(), String.t(), term()) :: :ok | {:error, ASM.Error.t() | term()}

  @callback subscribe(state(), String.t()) :: :ok | {:error, ASM.Error.t() | term()}
end

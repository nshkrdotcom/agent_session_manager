defmodule ASM.Pipeline.Plug do
  @moduledoc """
  Behaviour for synchronous run-event pipeline plugs.
  """

  @callback call(ASM.Event.t(), map(), keyword()) ::
              {:ok, ASM.Event.t(), map()}
              | {:ok, ASM.Event.t(), [ASM.Event.t()], map()}
              | {:halt, ASM.Event.t(), map()}
              | {:halt, ASM.Event.t(), [ASM.Event.t()], map()}
              | {:error, term(), map()}
end

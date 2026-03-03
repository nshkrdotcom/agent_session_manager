defmodule ASM.Tool do
  @moduledoc """
  Behaviour for run-time tool handlers.
  """

  @callback call(input :: map(), context :: map()) :: {:ok, term()} | {:error, term()}
end

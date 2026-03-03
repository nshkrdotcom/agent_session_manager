defmodule ASM.Command do
  @moduledoc """
  Behaviour for provider command builders.
  """

  alias ASM.Error
  alias ASM.Provider.Resolver

  @type command_spec :: Resolver.CommandSpec.t()
  @type command_args :: [String.t()]

  @callback build(String.t(), keyword()) ::
              {:ok, command_spec(), command_args()} | {:error, Error.t()}
end

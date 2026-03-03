defmodule ASM.Test do
  @moduledoc """
  Test helpers for quickly creating sessions and provider fixtures.
  """

  alias ASM.Provider

  @spec provider(atom()) :: Provider.t()
  def provider(name \\ :claude) do
    Provider.resolve!(name)
  end

  @spec unique_id(String.t()) :: String.t()
  def unique_id(prefix \\ "asm-test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end

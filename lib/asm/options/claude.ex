defmodule ASM.Options.Claude do
  @moduledoc """
  Claude provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      include_thinking: [type: :boolean, default: false],
      max_turns: [type: :pos_integer, default: 1]
    ]
  end
end

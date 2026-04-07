defmodule ASM.Options.Amp do
  @moduledoc """
  Amp provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      mode: [type: :string, default: "smart"],
      include_thinking: [type: :boolean, default: false],
      max_turns: [type: :pos_integer, default: 1],
      permissions: [type: {:or, [:map, nil]}, default: nil],
      mcp_config: [type: {:or, [:map, nil]}, default: nil],
      tools: [type: {:list, :string}, default: []]
    ]
  end
end

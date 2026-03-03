defmodule ASM.Options.Codex do
  @moduledoc """
  Codex exec provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      reasoning_effort: [type: {:in, [:low, :medium, :high, nil]}, default: nil],
      output_schema: [type: {:or, [:map, nil]}, default: nil]
    ]
  end
end

defmodule ASM.Options.Codex do
  @moduledoc """
  Codex exec provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      reasoning_effort: [type: {:in, [:low, :medium, :high, nil]}, default: nil],
      output_schema: [
        type: {:custom, ASM.Options, :validate_passthrough_map, [:output_schema]},
        default: nil
      ]
    ]
  end
end

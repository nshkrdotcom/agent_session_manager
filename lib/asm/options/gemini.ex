defmodule ASM.Options.Gemini do
  @moduledoc """
  Gemini provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      system_prompt: [type: {:or, [:string, nil]}, default: nil],
      sandbox: [type: :boolean, default: false],
      extensions: [type: {:list, :string}, default: []]
    ]
  end
end

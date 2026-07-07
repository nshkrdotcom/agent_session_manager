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
      extensions: [type: {:list, :string}, default: []],
      # Allow a Gemini model newer than the shared registry to pass through
      # to the CLI `--model` (default false = require a registered model).
      allow_unknown_model: [type: :boolean, default: false]
    ]
  end
end

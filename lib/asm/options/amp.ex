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
      permissions: [type: {:or, [:map, nil]}, default: nil],
      mcp_config: [type: {:or, [:map, nil]}, default: nil],
      tools: [type: {:list, :string}, default: []],
      # Allow an Amp model newer than the shared registry to pass through to
      # the CLI `--model` (default false = require a registered model).
      allow_unknown_model: [type: :boolean, default: false]
    ]
  end
end

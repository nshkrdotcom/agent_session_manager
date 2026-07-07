defmodule ASM.Options.Cursor do
  @moduledoc """
  Cursor Agent CLI provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      mode: [type: {:or, [{:in, [:agent, :plan, :ask]}, :string, nil]}, default: nil],
      sandbox: [
        type: {:or, [{:in, [:enabled, :disabled]}, :boolean, :string, nil]},
        default: nil
      ],
      approve_mcps: [type: :boolean, default: false],
      worktree: [type: {:or, [:string, :boolean, nil]}, default: nil],
      worktree_base: [type: {:or, [:string, nil]}, default: nil],
      skip_worktree_setup: [type: :boolean, default: false],
      plugin_dirs: [type: {:list, :string}, default: []],
      headers: [
        type: {:custom, ASM.Options, :validate_passthrough_list, [:headers]},
        default: []
      ],
      # Allow a Cursor model newer than the shared registry to pass through
      # to the CLI `--model` (default false = require a registered model).
      allow_unknown_model: [type: :boolean, default: false]
    ]
  end
end

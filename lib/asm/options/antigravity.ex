defmodule ASM.Options.Antigravity do
  @moduledoc """
  Antigravity CLI provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      sandbox: [type: :boolean, default: false],
      dangerously_skip_permissions: [type: :boolean, default: false],
      conversation: [type: {:or, [:string, nil]}, default: nil],
      continue: [type: :boolean, default: false],
      add_dirs: [type: {:list, :string}, default: []],
      print_timeout: [type: {:or, [:string, nil]}, default: nil],
      log_file: [type: {:or, [:string, nil]}, default: nil]
    ]
  end
end

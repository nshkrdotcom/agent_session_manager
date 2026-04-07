defmodule ASM.Options.Claude do
  @moduledoc """
  Claude provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      system_prompt: [type: {:or, [:string, :map, nil]}, default: nil],
      append_system_prompt: [type: {:or, [:string, nil]}, default: nil],
      provider_backend: [type: {:or, [{:in, [:anthropic, :ollama]}, :string, nil]}, default: nil],
      external_model_overrides: [
        type: {:custom, ASM.Options, :validate_passthrough_map, [:external_model_overrides]},
        default: %{}
      ],
      anthropic_base_url: [type: {:or, [:string, nil]}, default: nil],
      anthropic_auth_token: [type: {:or, [:string, nil]}, default: nil],
      include_thinking: [type: :boolean, default: false],
      max_turns: [type: :pos_integer, default: 1]
    ]
  end
end

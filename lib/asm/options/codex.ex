defmodule ASM.Options.Codex do
  @moduledoc """
  Codex exec provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      reasoning_effort: [
        type: {:or, [{:in, [:none, :minimal, :low, :medium, :high, :xhigh]}, :string, nil]},
        default: nil
      ],
      provider_backend: [
        type: {:or, [{:in, [:openai, :oss, :model_provider]}, :string, nil]},
        default: nil
      ],
      model_provider: [type: {:or, [:string, nil]}, default: nil],
      oss_provider: [type: {:or, [:string, nil]}, default: nil],
      ollama_base_url: [type: {:or, [:string, nil]}, default: nil],
      ollama_http: [type: {:or, [:boolean, nil]}, default: nil],
      ollama_timeout_ms: [type: {:or, [:pos_integer, nil]}, default: nil],
      output_schema: [
        type: {:custom, ASM.Options, :validate_passthrough_map, [:output_schema]},
        default: nil
      ]
    ]
  end
end

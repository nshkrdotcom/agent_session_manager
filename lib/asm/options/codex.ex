defmodule ASM.Options.Codex do
  @moduledoc """
  Codex exec provider-specific option schema.
  """

  @spec schema() :: keyword()
  def schema do
    [
      model: [type: :string],
      system_prompt: [type: {:or, [:string, nil]}, default: nil],
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
      skip_git_repo_check: [type: :boolean, default: false],
      app_server: [type: :boolean, default: false],
      host_tools: [
        type: {:custom, ASM.Options, :validate_passthrough_list, [:host_tools]},
        default: []
      ],
      dynamic_tools: [
        type: {:custom, ASM.Options, :validate_passthrough_list, [:dynamic_tools]},
        default: []
      ],
      output_schema: [
        type: {:custom, ASM.Options, :validate_passthrough_map, [:output_schema]},
        default: nil
      ],
      additional_directories: [type: {:list, :string}, default: []]
    ]
  end
end

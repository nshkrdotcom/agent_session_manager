Code.require_file("../common.exs", __DIR__)

defmodule ASM.PromotionPath.Common do
  @moduledoc false

  alias ASM.Examples.Common, as: ExampleCommon

  def config!(script_name, description, default_prompt, opts \\ []) do
    ExampleCommon.example_config!(script_name, description, default_prompt, opts)
  end

  def require_lane!(%ExampleCommon{lane: expected}, expected), do: :ok

  def require_lane!(%ExampleCommon{lane: lane}, expected) do
    raise "this promotion-path example requires lane #{inspect(expected)}, got #{inspect(lane)}"
  end

  def require_provider!(%ExampleCommon{} = config, provider) when is_atom(provider) do
    ExampleCommon.assert_provider!(config, provider)
  end

  def query_opts(%ExampleCommon{} = config) do
    config
    |> ExampleCommon.query_opts()
    |> Keyword.put_new(:execution_surface, execution_surface(config))
  end

  def execution_surface(%ExampleCommon{} = config) do
    Keyword.get(config.session_opts, :execution_surface) ||
      [
        surface_kind: :local_subprocess,
        observability: %{suite: :promotion_path, provider: config.provider, lane: config.lane}
      ]
  end

  def run_query!(%ExampleCommon{} = config, prompt, label) when is_binary(prompt) do
    result = ExampleCommon.query!(config.provider, prompt, query_opts(config))
    ExampleCommon.print_result_summary(result, label: label)
    result
  end

  def assert_smoke_text!(%ExampleCommon{} = config, result, expected, label) do
    ExampleCommon.assert_result_text_for_smoke!(config, result, expected, label: label)
  end

  def ensure_provider_sdk_loaded!(%ExampleCommon{} = config) do
    ExampleCommon.ensure_provider_sdk_loaded!(config.provider,
      sdk_root: config.sdk_root,
      cli_path: Keyword.get(config.session_opts, :cli_path)
    )
  end
end

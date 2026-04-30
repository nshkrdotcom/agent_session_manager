defmodule PromotionPath.ExampleBoundaryTest do
  use ExUnit.Case, async: true

  @promotion_path_dir Path.expand("../../examples/promotion_path", __DIR__)
  @asm_only_examples [
    "asm_core_lane.exs",
    "asm_sdk_backed_lane.exs"
  ]
  @forbidden_sdk_modules [
    AmpSdk,
    ClaudeAgentSDK,
    Codex,
    GeminiCliSdk
  ]

  test "ASM-only promotion examples do not reference provider SDK modules" do
    for example <- @asm_only_examples do
      modules = example |> read_example!() |> referenced_modules()

      assert MapSet.disjoint?(MapSet.new(modules), MapSet.new(@forbidden_sdk_modules)),
             "#{example} references provider SDK modules: #{inspect(modules)}"
    end
  end

  test "promotion examples do not import inference-owned examples" do
    for example <- Path.wildcard(Path.join(@promotion_path_dir, "*.exs")) do
      modules = example |> File.read!() |> referenced_modules()

      refute Inference in modules
    end
  end

  test "promotion path files are present for core, sdk-backed, and hybrid modes" do
    assert File.regular?(Path.join(@promotion_path_dir, "asm_core_lane.exs"))
    assert File.regular?(Path.join(@promotion_path_dir, "asm_sdk_backed_lane.exs"))
    assert File.regular?(Path.join(@promotion_path_dir, "hybrid_asm_plus_gemini.exs"))
    assert File.regular?(Path.join(@promotion_path_dir, "README.md"))
  end

  defp read_example!(example) do
    @promotion_path_dir
    |> Path.join(example)
    |> File.read!()
  end

  defp referenced_modules(source) when is_binary(source) do
    source
    |> Code.string_to_quoted!()
    |> collect_aliases()
  end

  defp collect_aliases(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, _metadata, parts} = node, acc ->
          {node, MapSet.put(acc, Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(modules)
  end
end

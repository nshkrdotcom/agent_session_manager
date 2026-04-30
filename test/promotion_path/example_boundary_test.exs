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
      violations = example |> read_example!() |> forbidden_references(@forbidden_sdk_modules)

      assert violations == [],
             "#{example} references provider SDK modules: #{inspect(violations)}"
    end
  end

  test "promotion examples do not import inference-owned examples" do
    for example <- Path.wildcard(Path.join(@promotion_path_dir, "*.exs")) do
      violations = example |> File.read!() |> forbidden_references([Inference])

      assert violations == []
    end
  end

  test "AST boundary helper catches imports, requires, remote calls, and apply dispatch" do
    source = """
    defmodule BadPromotionExample do
      import GeminiCliSdk
      require ClaudeAgentSDK

      def remote, do: Codex.query("prompt")
      def dynamic, do: apply(AmpSdk, :run, ["prompt"])

      defmacro macro_remote do
        quote do
          GeminiCliSdk.run("prompt")
        end
      end
    end
    """

    violations = forbidden_references(source, @forbidden_sdk_modules)

    assert Enum.any?(violations, &match?(%{kind: :import, module: GeminiCliSdk}, &1))
    assert Enum.any?(violations, &match?(%{kind: :require, module: ClaudeAgentSDK}, &1))
    assert Enum.any?(violations, &match?(%{kind: :remote_call, module: Codex}, &1))
    assert Enum.any?(violations, &match?(%{kind: :apply, module: AmpSdk}, &1))
    assert Enum.any?(violations, &match?(%{kind: :remote_call, module: GeminiCliSdk}, &1))
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

  defp forbidden_references(source, forbidden_modules) when is_binary(source) do
    source
    |> Code.string_to_quoted!()
    |> collect_forbidden_references(forbidden_modules)
  end

  defp collect_forbidden_references(ast, forbidden_modules) do
    forbidden_parts = Enum.map(forbidden_modules, &Module.split/1)

    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        violations = references_for(node, forbidden_parts)
        {node, violations ++ acc}
      end)

    Enum.reverse(violations)
  end

  defp references_for({op, meta, [{:__aliases__, _, parts} | _rest]}, forbidden_parts)
       when op in [:alias, :import, :require] do
    violation(op, parts, meta, forbidden_parts)
  end

  defp references_for(
         {{:., meta, [{:__aliases__, _, parts}, function]}, _, _args},
         forbidden_parts
       ) do
    violation(:remote_call, parts, meta, forbidden_parts, function)
  end

  defp references_for(
         {:apply, meta, [{:__aliases__, _, parts}, function, _args]},
         forbidden_parts
       ) do
    violation(:apply, parts, meta, forbidden_parts, function)
  end

  defp references_for({:__aliases__, meta, parts}, forbidden_parts) do
    violation(:module_reference, parts, meta, forbidden_parts)
  end

  defp references_for(_node, _forbidden_parts), do: []

  defp violation(kind, parts, meta, forbidden_parts, function \\ nil) do
    module_parts = alias_parts(parts)
    forbidden = Enum.find(forbidden_parts, &prefix_match?(module_parts, &1))

    if forbidden do
      module = Module.concat(forbidden)

      [
        %{
          kind: kind,
          module: module,
          function: function,
          line: meta[:line]
        }
      ]
    else
      []
    end
  end

  defp alias_parts([:"Elixir" | rest]), do: Enum.map(rest, &to_string/1)
  defp alias_parts(parts), do: Enum.map(parts, &to_string/1)

  defp prefix_match?(parts, forbidden_parts) do
    Enum.take(parts, length(forbidden_parts)) == forbidden_parts
  end
end

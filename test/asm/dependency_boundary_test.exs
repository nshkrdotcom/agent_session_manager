defmodule ASM.DependencyBoundaryTest do
  use ASM.TestCase

  @forbidden_deps [
    :execution_plane,
    :execution_plane_process,
    :execution_plane_jsonrpc,
    :gemini_cli_sdk,
    :claude_agent_sdk,
    :codex_sdk,
    :amp_sdk,
    :inference
  ]

  test "ASM does not declare lower execution_plane, provider SDK, or inference deps" do
    assert_forbidden_deps_absent(Mix.Project.config()[:deps], @forbidden_deps)
  end

  defp assert_forbidden_deps_absent(deps, forbidden_deps) when is_list(deps) do
    declared = MapSet.new(Enum.map(deps, &dep_name/1))

    Enum.each(forbidden_deps, fn dep ->
      refute MapSet.member?(declared, dep),
             "agent_session_manager must not declare dependency on #{inspect(dep)}"
    end)
  end

  defp dep_name({name, _requirement}), do: name
  defp dep_name({name, _requirement, _opts}), do: name
end

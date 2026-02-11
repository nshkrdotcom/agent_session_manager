defmodule AgentSessionManager.MixProjectDepsTest do
  use AgentSessionManager.SupertesterCase, async: true

  test "provider SDK dependencies are marked optional" do
    deps = AgentSessionManager.MixProject.project()[:deps]

    assert optional_dep?(deps, :codex_sdk)
    assert optional_dep?(deps, :claude_agent_sdk)
    assert optional_dep?(deps, :amp_sdk)
  end

  defp optional_dep?(deps, dep_name) do
    deps
    |> Enum.find(fn
      {^dep_name, _, _} -> true
      {^dep_name, _} -> true
      _ -> false
    end)
    |> dep_optional?()
  end

  defp dep_optional?({_, _requirement, opts}) when is_list(opts) do
    Keyword.get(opts, :optional, false)
  end

  defp dep_optional?({_, opts}) when is_list(opts) do
    Keyword.get(opts, :optional, false)
  end

  defp dep_optional?(_dep), do: false
end

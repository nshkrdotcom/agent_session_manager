defmodule ASM.ExecTest do
  use ASM.TestCase

  alias ASM.Exec

  test "build_argv/2 returns charlist argv preserving argument boundaries" do
    argv = Exec.build_argv("echo", ["hello world", "a'b", "x=y"])

    assert argv == Enum.map(["echo", "hello world", "a'b", "x=y"], &to_charlist/1)
  end

  test "add_env/2 normalizes keys and values to charlists" do
    opts = Exec.add_env([], %{"A" => 1, b: true})

    assert [{:env, env}] = opts
    assert {"A", "1"} in Enum.map(env, fn {k, v} -> {List.to_string(k), List.to_string(v)} end)
    assert {"b", "true"} in Enum.map(env, fn {k, v} -> {List.to_string(k), List.to_string(v)} end)
  end
end

defmodule ASM.Runtime.SafetyTest do
  use ASM.TestCase

  test "core runtime does not use unlinked Task.start/1" do
    root = Path.expand("../../..", __DIR__)
    lib_files = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))

    offenders =
      Enum.filter(lib_files, fn file ->
        file
        |> File.read!()
        |> String.contains?("Task.start(")
      end)

    assert offenders == []
  end
end

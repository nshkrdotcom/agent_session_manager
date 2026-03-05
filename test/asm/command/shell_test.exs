defmodule ASM.Command.ShellTest do
  use ASM.TestCase

  alias ASM.Command.Shell

  test "build/2 resolves shell path and produces safe exec wrapper args" do
    assert {:ok, spec, args} =
             Shell.build("echo hello",
               allowed_commands: ["echo"],
               denied_commands: [],
               env: fn _ -> nil end,
               find_executable: fn
                 "sh" -> "/bin/sh"
                 _ -> nil
               end
             )

    assert spec.program == "/bin/sh"
    assert ["-lc", command] = args
    assert command =~ "exec"
    assert command =~ "'echo'"
    assert command =~ "'hello'"
  end

  test "build/2 denies command not present in allow-list" do
    assert {:error, error} =
             Shell.build("uname -a",
               allowed_commands: ["echo"],
               denied_commands: [],
               env: fn _ -> nil end,
               find_executable: fn
                 "sh" -> "/bin/sh"
                 _ -> nil
               end
             )

    assert error.kind == :policy_violation
    assert error.message =~ "allowed list"
  end

  test "build/2 denies metacharacter command chaining attempts" do
    assert {:error, error} =
             Shell.build("echo ok; rm -rf /",
               allowed_commands: ["echo"],
               denied_commands: [],
               env: fn _ -> nil end,
               find_executable: fn
                 "sh" -> "/bin/sh"
                 _ -> nil
               end
             )

    assert error.kind == :policy_violation
  end
end

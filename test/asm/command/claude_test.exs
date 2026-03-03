defmodule ASM.Command.ClaudeTest do
  use ExUnit.Case, async: true

  alias ASM.Command.Claude

  test "build/2 resolves command and appends required args" do
    assert {:ok, spec, args} =
             Claude.build("hello",
               model: "claude-sonnet-4",
               permission_mode: :auto,
               env: fn _ -> nil end,
               find_executable: fn
                 "claude" -> "/usr/bin/claude"
                 _ -> nil
               end
             )

    assert spec.program == "/usr/bin/claude"
    assert ["--output-format", "stream-json", "--verbose", "--print"] == Enum.take(args, 4)
    assert contains_pair?(args, "--model", "claude-sonnet-4")
    assert contains_pair?(args, "--permission-mode", "acceptEdits")
    assert List.last(args) == "hello"
  end

  test "provider_permission_mode is preferred when present" do
    args = Claude.to_cli_args(provider_permission_mode: :bypass_permissions)
    assert contains_pair?(args, "--permission-mode", "bypassPermissions")
  end

  defp contains_pair?(args, flag, value) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      [^flag, ^value] -> true
      _ -> false
    end)
  end
end

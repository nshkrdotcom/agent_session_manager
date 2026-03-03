defmodule ASM.Command.CodexTest do
  use ExUnit.Case, async: true

  alias ASM.Command.Codex

  test "build/2 resolves command and appends codex exec flags" do
    assert {:ok, spec, args} =
             Codex.build("hello codex",
               model: "gpt-5-codex",
               reasoning_effort: :high,
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "codex" -> "/usr/bin/codex"
                 _ -> nil
               end
             )

    assert spec.program == "/usr/bin/codex"
    assert ["exec", "--json"] == Enum.take(args, 2)
    assert contains_pair?(args, "--model", "gpt-5-codex")
    assert contains_pair?(args, "--reasoning-effort", "high")
    assert "--dangerously-bypass-approvals-and-sandbox" in args
    assert List.last(args) == "hello codex"
  end

  test "provider_permission_mode override is honored" do
    args = Codex.option_flags(provider_permission_mode: :auto_edit)
    assert "--full-auto" in args
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

defmodule ASM.Command.CodexTest do
  use ExUnit.Case, async: true

  alias ASM.Command.Codex
  alias ASM.Options

  test "build/2 resolves command and appends codex exec flags" do
    assert {:ok, spec, args} =
             Codex.build("hello codex",
               model: "gpt-5-codex",
               reasoning_effort: :high,
               permission_mode: :bypass,
               system_cmd: fn _, _ -> {"--reasoning-effort", 0} end,
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

  test "default codex options do not force a deprecated reasoning flag" do
    validated = Options.validate!([provider: :codex_exec], ASM.Options.Codex.schema())
    args = Codex.build_args("hello codex", validated)

    refute "--reasoning-effort" in args
  end

  test "plan permission mode does not emit unsupported codex flag" do
    args = Codex.option_flags(provider_permission_mode: :plan)

    refute "--plan" in args
  end

  test "explicit reasoning effort is skipped when codex flag is unavailable" do
    assert {:ok, _spec, args} =
             Codex.build("hello codex",
               reasoning_effort: :high,
               system_cmd: fn _, _ -> {"Usage: codex exec", 0} end,
               env: fn _ -> nil end,
               find_executable: fn
                 "codex" -> "/usr/bin/codex"
                 _ -> nil
               end
             )

    refute "--reasoning-effort" in args
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

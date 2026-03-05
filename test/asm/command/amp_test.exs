defmodule ASM.Command.AmpTest do
  use ASM.TestCase

  alias ASM.Command.Amp

  test "build/2 resolves command and appends amp flags" do
    assert {:ok, spec, args} =
             Amp.build("hello amp",
               model: "amp-1",
               mode: "smart",
               include_thinking: true,
               tools: ["bash", "edit_file"],
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "amp" -> "/usr/bin/amp"
                 _ -> nil
               end
             )

    assert spec.program == "/usr/bin/amp"
    assert ["run", "--output", "jsonl"] == Enum.take(args, 3)
    assert contains_pair?(args, "--model", "amp-1")
    assert contains_pair?(args, "--mode", "smart")
    assert "--thinking" in args
    assert contains_pair?(args, "--tool", "bash")
    assert contains_pair?(args, "--tool", "edit_file")
    assert "--dangerously-allow-all" in args
    assert List.last(args) == "hello amp"
  end

  test "provider_permission_mode override is honored" do
    args = Amp.option_flags(provider_permission_mode: :plan)
    assert contains_pair?(args, "--permission-mode", "plan")
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

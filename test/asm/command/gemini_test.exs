defmodule ASM.Command.GeminiTest do
  use ASM.TestCase

  alias ASM.Command.Gemini

  test "build/2 resolves command and emits prompt flag args" do
    assert {:ok, spec, args} =
             Gemini.build("hello gemini",
               model: "gemini-2.5-pro",
               sandbox: true,
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "gemini" -> "/usr/bin/gemini"
                 _ -> nil
               end
             )

    assert spec.program == "/usr/bin/gemini"
    assert Enum.take(args, 4) == ["--prompt", "hello gemini", "--output-format", "stream-json"]
    assert contains_pair?(args, "--model", "gemini-2.5-pro")
    assert "--sandbox" in args
    assert "--yolo" in args
  end

  test "provider_permission_mode override maps to approval mode" do
    args = Gemini.option_flags(provider_permission_mode: :auto_edit)
    assert contains_pair?(args, "--approval-mode", "auto_edit")
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

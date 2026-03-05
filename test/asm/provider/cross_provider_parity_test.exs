defmodule ASM.Provider.CrossProviderParityTest do
  use ASM.TestCase

  alias ASM.Message
  alias ASM.Parser

  test "delta parsing yields consistent assistant_delta payloads" do
    samples = [
      {Parser.Claude, %{"type" => "assistant_delta", "delta" => "hello"}},
      {Parser.Codex, %{"type" => "response.output_text.delta", "delta" => "hello"}},
      {Parser.Gemini,
       %{"type" => "message", "role" => "assistant", "content" => "hello", "delta" => true}},
      {Parser.Amp, %{"type" => "message_streamed", "delta" => "hello"}}
    ]

    Enum.each(samples, fn {module, raw} ->
      assert {:ok, {:assistant_delta, %Message.Partial{} = payload}} = module.parse(raw)
      assert payload.content_type == :text
      assert payload.delta == "hello"
    end)
  end

  test "result parsing yields consistent token usage keys" do
    samples = [
      {Parser.Claude,
       %{
         "type" => "result",
         "stop_reason" => "end_turn",
         "usage" => %{"input_tokens" => 2, "output_tokens" => 3}
       }},
      {Parser.Codex,
       %{
         "type" => "turn.completed",
         "stop_reason" => "end_turn",
         "usage" => %{"input_tokens" => 2, "output_tokens" => 3}
       }},
      {Parser.Gemini,
       %{
         "type" => "result",
         "status" => "end_turn",
         "stats" => %{"input_tokens" => 2, "output_tokens" => 3}
       }},
      {Parser.Amp,
       %{
         "type" => "run_completed",
         "stop_reason" => "end_turn",
         "token_usage" => %{"input_tokens" => 2, "output_tokens" => 3}
       }}
    ]

    Enum.each(samples, fn {module, raw} ->
      assert {:ok, {:result, %Message.Result{} = payload}} = module.parse(raw)
      assert payload.stop_reason == "end_turn"
      assert payload.usage.input_tokens == 2
      assert payload.usage.output_tokens == 3
    end)
  end

  test "command builders map bypass permission appropriately per provider" do
    providers = [
      {ASM.Command.Claude, "claude", "/usr/bin/claude"},
      {ASM.Command.Codex, "codex", "/usr/bin/codex"},
      {ASM.Command.Gemini, "gemini", "/usr/bin/gemini"},
      {ASM.Command.Amp, "amp", "/usr/bin/amp"}
    ]

    Enum.each(providers, fn {module, binary_name, expected_path} ->
      assert {:ok, spec, args} =
               module.build("prompt",
                 permission_mode: :bypass,
                 env: fn _ -> nil end,
                 find_executable: fn
                   ^binary_name -> expected_path
                   _ -> nil
                 end
               )

      assert spec.program == expected_path
      assert List.last(args) == "prompt" or Enum.at(args, 1) == "prompt"
    end)

    assert {:ok, _spec, claude_args} =
             ASM.Command.Claude.build("prompt",
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "claude" -> "/usr/bin/claude"
                 _ -> nil
               end
             )

    assert {:ok, _spec, codex_args} =
             ASM.Command.Codex.build("prompt",
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "codex" -> "/usr/bin/codex"
                 _ -> nil
               end
             )

    assert {:ok, _spec, gemini_args} =
             ASM.Command.Gemini.build("prompt",
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "gemini" -> "/usr/bin/gemini"
                 _ -> nil
               end
             )

    assert {:ok, _spec, amp_args} =
             ASM.Command.Amp.build("prompt",
               permission_mode: :bypass,
               env: fn _ -> nil end,
               find_executable: fn
                 "amp" -> "/usr/bin/amp"
                 _ -> nil
               end
             )

    assert contains_pair?(claude_args, "--permission-mode", "bypassPermissions")
    assert "--dangerously-bypass-approvals-and-sandbox" in codex_args
    assert "--yolo" in gemini_args
    assert "--dangerously-allow-all" in amp_args
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

defmodule ASM.RunAllTest do
  use ASM.TestCase

  @project_root Path.expand("../..", __DIR__)

  test "run_all.sh prints usage and exits when no provider is selected" do
    assert {output, 0} =
             System.cmd("bash", ["examples/run_all.sh"],
               cd: @project_root,
               stderr_to_stdout: true
             )

    assert String.contains?(
             output,
             "run_all.sh only runs when you explicitly choose one or more providers"
           )

    assert String.contains?(output, "./examples/run_all.sh --provider claude")
  end

  test "run_all.sh fans out providers and forwards extra flags" do
    tmp_dir = Path.join(System.tmp_dir!(), "asm_run_all_#{System.unique_integer([:positive])}")
    fake_mix = Path.join(tmp_dir, "mix")

    File.mkdir_p!(tmp_dir)
    File.write!(fake_mix, "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\"\n")
    File.chmod!(fake_mix, 0o755)

    path = "#{tmp_dir}:#{System.get_env("PATH")}"

    assert {output, 0} =
             System.cmd(
               "bash",
               ["examples/run_all.sh", "--provider", "codex,amp", "--foo", "bar"],
               cd: @project_root,
               env: [{"PATH", path}],
               stderr_to_stdout: true
             )

    assert String.contains?(output, "== live_query.exs provider=codex ==")
    assert String.contains?(output, "== provider_codex_app_server.exs provider=codex ==")
    assert String.contains?(output, "== live_query.exs provider=amp ==")
    assert String.contains?(output, "== provider_amp_sdk_stream.exs provider=amp ==")

    assert String.contains?(
             output,
             "run --no-start examples/live_query.exs -- --provider codex --foo bar"
           )

    assert String.contains?(
             output,
             "run --no-start examples/provider_amp_sdk_stream.exs -- --provider amp --foo bar"
           )
  end

  test "run_all.sh rejects the common Ollama surface for unsupported providers" do
    assert {output, 1} =
             System.cmd(
               "bash",
               ["examples/run_all.sh", "--provider", "amp", "--ollama"],
               cd: @project_root,
               stderr_to_stdout: true
             )

    assert String.contains?(output, "provider amp does not support the ASM common Ollama surface")
    assert String.contains?(output, "only valid for claude and codex")
  end
end

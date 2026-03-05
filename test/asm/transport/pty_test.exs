defmodule ASM.Transport.PTYTest do
  use ASM.SerialTestCase

  alias ASM.Transport.PTY

  setup do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      restore_path(original_path)
    end)

    :ok
  end

  test "maybe_wrap/3 falls back to direct command when script probe fails" do
    {script_dir, script_path} =
      write_fake_script!("""
      #!/usr/bin/env bash
      exit 1
      """)

    prepend_path!(script_dir)

    provider = ASM.Provider.resolve!(:claude)

    assert {"claude", ["--print", "ok"]} ==
             PTY.maybe_wrap(provider, "claude", ["--print", "ok"])

    assert System.find_executable("script") == script_path
  end

  test "maybe_wrap/3 uses script wrapper when probe succeeds" do
    {script_dir, script_path} =
      write_fake_script!("""
      #!/usr/bin/env bash
      exit 0
      """)

    prepend_path!(script_dir)

    provider = ASM.Provider.resolve!(:claude)
    {program, args} = PTY.maybe_wrap(provider, "claude", ["--print", "ok"])

    assert program == script_path
    assert Enum.take(args, 2) == ["-q", "-c"]
    assert List.last(args) == "/dev/null"
  end

  test "maybe_wrap/3 never wraps non-claude providers" do
    {script_dir, _script_path} =
      write_fake_script!("""
      #!/usr/bin/env bash
      exit 0
      """)

    prepend_path!(script_dir)

    provider = ASM.Provider.resolve!(:codex)

    assert {"codex", ["exec"]} == PTY.maybe_wrap(provider, "codex", ["exec"])
  end

  defp write_fake_script!(contents) do
    script_dir =
      Path.join(
        System.tmp_dir!(),
        "asm-fake-script-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(script_dir)
    script_path = Path.join(script_dir, "script")
    File.write!(script_path, contents)
    File.chmod!(script_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(script_dir)
    end)

    {script_dir, script_path}
  end

  defp prepend_path!(script_dir) do
    current_path = System.get_env("PATH", "")
    System.put_env("PATH", script_dir <> ":" <> current_path)
  end

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(path), do: System.put_env("PATH", path)
end

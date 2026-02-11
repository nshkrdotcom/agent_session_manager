defmodule AgentSessionManager.Workspace.ExecTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Workspace.Exec

  # NOTE: These tests run REAL shell commands. This is intentional.
  # The module's purpose is OS process management.

  describe "run/3" do
    test "executes a simple command and captures stdout" do
      assert {:ok, result} = Exec.run("echo", ["hello"])
      assert result.exit_code == 0
      assert String.trim(result.stdout) == "hello"
      assert result.timed_out == false
      assert result.duration_ms >= 0
      assert result.command == "echo"
      assert result.args == ["hello"]
    end

    test "captures non-zero exit code" do
      assert {:ok, result} = Exec.run("false", [])
      assert result.exit_code != 0
      assert result.timed_out == false
    end

    test "returns {:ok, result} even for non-zero exit codes" do
      # Workspace.Exec does NOT treat non-zero exit as an error.
      # The caller (or ShellAdapter) decides.
      assert {:ok, result} = Exec.run("sh", ["-c", "exit 42"])
      assert result.exit_code == 42
    end

    test "respects timeout and sets timed_out flag" do
      assert {:ok, result} = Exec.run("sleep", ["10"], timeout_ms: 200)
      assert result.timed_out == true
      assert result.duration_ms >= 200
    end

    test "respects cwd option" do
      assert {:ok, result} = Exec.run("pwd", [], cwd: "/tmp")
      assert String.trim(result.stdout) == "/tmp"
    end

    test "returns error for nonexistent cwd" do
      assert {:error, error} = Exec.run("echo", ["hi"], cwd: "/nonexistent_dir_xyz_12345")
      assert error.code == :validation_error
    end

    test "captures stderr" do
      assert {:ok, result} = Exec.run("sh", ["-c", "echo err >&2"])
      # Note: with Port.open :stderr_to_stdout, stderr goes to stdout.
      # If separated, it goes to result.stderr.
      # Either way, the output must contain "err".
      output = result.stdout <> (result.stderr || "")
      assert output =~ "err"
    end

    test "sets environment variables" do
      assert {:ok, result} =
               Exec.run("sh", ["-c", "echo $MY_TEST_VAR"],
                 env: [{"MY_TEST_VAR", "hello_from_test"}]
               )

      assert String.trim(result.stdout) =~ "hello_from_test"
    end

    test "enforces max_output_bytes by truncating" do
      # `yes` produces infinite output; with timeout it will produce some output
      assert {:ok, result} = Exec.run("yes", [], timeout_ms: 300, max_output_bytes: 1024)
      # Output should be truncated around max_output_bytes (allow buffer for final chunk)
      assert byte_size(result.stdout) <= 1024 + 512
    end

    test "returns error for command not found" do
      assert {:error, error} = Exec.run("nonexistent_command_xyz_98765", [])
      assert error.code in [:command_not_found, :internal_error]
    end

    test "uses default timeout when not specified" do
      # Should not hang -- the default timeout (30s) prevents infinite execution.
      # Use a fast command to verify it completes normally.
      assert {:ok, result} = Exec.run("echo", ["default_timeout_test"])
      assert result.exit_code == 0
    end

    test "records duration_ms accurately" do
      assert {:ok, result} = Exec.run("sleep", ["0.1"])
      assert result.duration_ms >= 50
    end

    test "on_output callback receives chunks" do
      test_pid = self()
      callback = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, _result} = Exec.run("echo", ["callback_test"], on_output: callback)

      # Should have received at least one stdout chunk
      assert_receive {:chunk, {:stdout, data}}, 1000
      assert data =~ "callback_test"
    end
  end

  describe "run/3 with shell string input" do
    test "handles piped commands via shell wrapping" do
      assert {:ok, result} = Exec.run("sh", ["-c", "echo hello | tr a-z A-Z"])
      assert String.trim(result.stdout) == "HELLO"
    end
  end

  describe "run_streaming/3" do
    test "yields output chunks as a stream" do
      chunks = Exec.run_streaming("echo", ["stream_test"]) |> Enum.to_list()

      assert Enum.any?(chunks, fn
               {:stdout, data} -> data =~ "stream_test"
               _ -> false
             end)

      assert List.last(chunks) |> elem(0) == :exit
    end

    test "stream terminates with {:exit, code}" do
      chunks = Exec.run_streaming("true", []) |> Enum.to_list()
      last = List.last(chunks)
      assert {:exit, 0} = last
    end

    test "stream captures non-zero exit" do
      chunks = Exec.run_streaming("false", []) |> Enum.to_list()
      last = List.last(chunks)
      assert {:exit, code} = last
      assert code != 0
    end

    test "stream respects timeout" do
      chunks = Exec.run_streaming("sleep", ["10"], timeout_ms: 200) |> Enum.to_list()
      # Should terminate (not hang forever)
      assert is_list(chunks)
    end
  end
end

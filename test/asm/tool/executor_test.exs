defmodule ASM.Tool.ExecutorTest do
  use ASM.TestCase

  alias ASM.{Message, Run, Tool}
  alias ASM.Tool.Executor

  defmodule EchoTool do
    @behaviour Tool

    @impl true
    def call(input, _context) do
      {:ok, input["text"]}
    end
  end

  test "executes function-based tools" do
    state =
      Run.State.new(
        run_id: "run-tool-fn",
        session_id: "session-tool-fn",
        provider: :claude,
        tools: %{
          "echo" => fn input, _context -> {:ok, input["text"]} end
        }
      )

    tool_use = %Message.ToolUse{tool_name: "echo", tool_id: "tool-1", input: %{"text" => "hi"}}
    result = Executor.execute(tool_use, state)

    assert result.tool_id == "tool-1"
    assert result.content == "hi"
    assert result.is_error == false
  end

  test "executes module-based tools" do
    state =
      Run.State.new(
        run_id: "run-tool-module",
        session_id: "session-tool-module",
        provider: :claude,
        tools: %{"echo_mod" => EchoTool}
      )

    tool_use =
      %Message.ToolUse{tool_name: "echo_mod", tool_id: "tool-2", input: %{"text" => "hello"}}

    result = Executor.execute(tool_use, state)

    assert result.content == "hello"
    assert result.is_error == false
  end

  test "missing tool returns error result payload" do
    state =
      Run.State.new(
        run_id: "run-tool-missing",
        session_id: "session-tool-missing",
        provider: :claude
      )

    tool_use = %Message.ToolUse{tool_name: "missing", tool_id: "tool-3", input: %{}}

    result = Executor.execute(tool_use, state)

    assert result.tool_id == "tool-3"
    assert result.is_error == true
    assert is_binary(result.content)
  end
end

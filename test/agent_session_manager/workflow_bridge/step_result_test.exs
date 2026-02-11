defmodule AgentSessionManager.WorkflowBridge.StepResultTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.WorkflowBridge.StepResult

  test "defaults and struct fields" do
    result = %StepResult{}

    assert result.output == nil
    assert result.content == nil
    assert result.token_usage == %{}
    assert result.session_id == nil
    assert result.run_id == nil
    assert result.events == []
    assert result.stop_reason == nil
    assert result.tool_calls == []
    assert result.has_tool_calls == false
    assert result.persistence_failures == 0
    assert result.workspace == nil
    assert result.policy == nil
    assert result.retryable == false
  end

  test "accepts explicit values" do
    result = %StepResult{
      output: %{content: "ok"},
      content: "ok",
      token_usage: %{input_tokens: 1},
      session_id: "ses_1",
      run_id: "run_1",
      events: [%{type: :run_completed}],
      stop_reason: "end_turn",
      tool_calls: [%{id: "tool_1"}],
      has_tool_calls: true,
      persistence_failures: 1,
      workspace: %{backend: :git},
      policy: %{action: :warn},
      retryable: false
    }

    assert result.output == %{content: "ok"}
    assert result.content == "ok"
    assert result.token_usage == %{input_tokens: 1}
    assert result.session_id == "ses_1"
    assert result.run_id == "run_1"
    assert result.stop_reason == "end_turn"
    assert result.tool_calls == [%{id: "tool_1"}]
    assert result.has_tool_calls == true
    assert result.persistence_failures == 1
    assert result.workspace == %{backend: :git}
    assert result.policy == %{action: :warn}
    assert result.retryable == false
  end
end

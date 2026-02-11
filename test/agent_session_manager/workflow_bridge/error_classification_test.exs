defmodule AgentSessionManager.WorkflowBridge.ErrorClassificationTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.WorkflowBridge
  alias AgentSessionManager.WorkflowBridge.ErrorClassification

  test "struct defaults" do
    classification = %ErrorClassification{}

    assert classification.error == nil
    assert classification.retryable == false
    assert classification.category == nil
    assert classification.recommended_action == nil
  end

  test "classify_error/1 returns classification for all known error codes" do
    Enum.each(Error.all_codes(), fn code ->
      classification = WorkflowBridge.classify_error(Error.new(code, "msg"))

      assert %ErrorClassification{} = classification
      assert classification.error.code == code
      assert is_boolean(classification.retryable)
      assert is_atom(classification.category)

      assert classification.recommended_action in [
               :retry,
               :failover,
               :abort,
               :wait_and_retry,
               :cancel
             ]
    end)
  end

  test "special-case action mappings" do
    assert WorkflowBridge.classify_error(Error.new(:provider_rate_limited, "x")).recommended_action ==
             :wait_and_retry

    assert WorkflowBridge.classify_error(Error.new(:provider_unavailable, "x")).recommended_action ==
             :failover

    assert WorkflowBridge.classify_error(Error.new(:policy_violation, "x")).recommended_action ==
             :cancel
  end
end

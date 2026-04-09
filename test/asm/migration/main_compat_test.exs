defmodule ASM.Migration.MainCompatTest do
  use ASM.TestCase

  alias ASM.{Content, Control, Event, Message}
  alias ASM.Migration.MainCompat

  describe "resolve_provider/1" do
    test "maps main adapter identifiers to rebuild providers" do
      assert {:ok, :claude} =
               MainCompat.resolve_provider("AgentSessionManager.Adapters.ClaudeAdapter")

      assert {:ok, :codex} =
               MainCompat.resolve_provider("AgentSessionManager.Adapters.CodexAdapter")

      assert {:ok, :gemini} = MainCompat.resolve_provider(:gemini)
      assert {:ok, :codex} = MainCompat.resolve_provider(:codex_exec)
    end

    test "returns explicit unsupported error for amp and shell gaps" do
      assert {:error, amp_error} =
               MainCompat.resolve_provider("AgentSessionManager.Adapters.AmpAdapter")

      assert amp_error.kind == :config_invalid
      assert amp_error.domain == :config
      assert amp_error.message =~ "Amp"
      assert amp_error.message =~ "unsupported"

      assert {:error, shell_error} = MainCompat.resolve_provider(:shell)
      assert shell_error.kind == :config_invalid
      assert shell_error.domain == :config
      assert shell_error.message =~ "Shell"
      assert shell_error.message =~ "unsupported"
    end
  end

  describe "input_to_prompt/1" do
    test "converts prompt map input" do
      assert {:ok, "summarize this"} = MainCompat.input_to_prompt(%{prompt: "summarize this"})
    end

    test "converts message list into role-prefixed prompt lines" do
      input = %{
        messages: [
          %{role: "system", content: "be concise"},
          %{role: :user, content: "hello"},
          %{"role" => "assistant", "content" => "hi"},
          %{role: nil, content: %{nested: true}}
        ]
      }

      assert {:ok, prompt} = MainCompat.input_to_prompt(input)

      assert prompt ==
               "system: be concise\nuser: hello\nassistant: hi\nuser: %{nested: true}"
    end

    test "returns config error for unsupported input shape" do
      assert {:error, error} = MainCompat.input_to_prompt(%{messages: []})
      assert error.kind == :config_invalid
      assert error.domain == :config
      assert error.message =~ "input"
    end
  end

  describe "build_query/3" do
    test "rejects migrated Codex full_auto onto ASM codex auto mode" do
      input = %{messages: [%{role: "user", content: "Refactor this"}]}

      opts = [
        agent_id: "agent-main",
        metadata: %{request_id: "req-123"},
        context: %{system_prompt: "be direct"},
        tags: ["migration"],
        permission_mode: :full_auto,
        adapter_opts: [
          working_directory: "/tmp/project",
          model: "gpt-5.4",
          reasoning_effort: :high
        ]
      ]

      assert {:error, error} = MainCompat.build_query(:codex, input, opts)

      assert error.message =~ "Permission mode :auto is not valid for provider :codex_exec"
    end

    test "returns explicit unsupported error for unsupported main options" do
      assert {:error, error} =
               MainCompat.build_query(:claude, %{prompt: "hello"}, continuation: :auto)

      assert error.kind == :config_invalid
      assert error.domain == :config
      assert error.message =~ "continuation"
      assert error.message =~ "unsupported"
    end
  end

  describe "bridge_event/1" do
    test "bridges assistant delta into legacy message_streamed shape" do
      event = %Event{
        id: "evt-1",
        kind: :assistant_delta,
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        payload: %Message.Partial{content_type: :text, delta: "hello"},
        timestamp: DateTime.utc_now()
      }

      assert [legacy] = MainCompat.bridge_event(event)
      assert legacy.type == :message_streamed
      assert legacy.provider == :claude
      assert legacy.data == %{content: "hello", delta: "hello"}
    end

    test "bridges result payload to token usage and run completion legacy events" do
      event = %Event{
        id: "evt-2",
        kind: :result,
        run_id: "run-1",
        session_id: "session-1",
        provider: :codex,
        payload: %Message.Result{
          stop_reason: :end_turn,
          usage: %{input_tokens: 3, output_tokens: 5},
          duration_ms: 42,
          metadata: %{source: :parser}
        },
        timestamp: DateTime.utc_now()
      }

      legacy = MainCompat.bridge_event(event)

      assert Enum.map(legacy, & &1.type) == [:token_usage_updated, :run_completed]

      [token_usage_updated, run_completed] = legacy

      assert token_usage_updated.data == %{input_tokens: 3, output_tokens: 5}

      assert run_completed.data == %{
               stop_reason: :end_turn,
               duration_ms: 42,
               token_usage: %{input_tokens: 3, output_tokens: 5},
               metadata: %{source: :parser}
             }
    end

    test "bridges approvals and guardrails into legacy approval/policy events" do
      approval_event = %Event{
        id: "evt-3",
        kind: :approval_resolved,
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        payload: %Control.ApprovalResolution{approval_id: "a-1", decision: :allow, reason: nil},
        timestamp: DateTime.utc_now()
      }

      assert [approval] = MainCompat.bridge_event(approval_event)
      assert approval.type == :tool_approval_granted
      assert approval.data == %{approval_id: "a-1", reason: nil}

      guardrail_event = %Event{
        id: "evt-4",
        kind: :guardrail_triggered,
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        payload: %Control.GuardrailTrigger{rule: "deny_rm", direction: :output, action: :block},
        timestamp: DateTime.utc_now()
      }

      assert [policy] = MainCompat.bridge_event(guardrail_event)
      assert policy.type == :policy_violation
      assert policy.data == %{policy: "deny_rm", kind: :output, action: :block}
    end

    test "bridges assistant message and errors with explicit legacy structures" do
      assistant_event = %Event{
        id: "evt-5",
        kind: :assistant_message,
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        payload: %Message.Assistant{content: [%Content.Text{text: "done"}], metadata: %{}},
        timestamp: DateTime.utc_now()
      }

      assert [assistant] = MainCompat.bridge_event(assistant_event)
      assert assistant.type == :message_received
      assert assistant.data == %{content: "done", role: "assistant"}

      error_event = %Event{
        id: "evt-6",
        kind: :error,
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        payload: %Message.Error{severity: :error, message: "boom", kind: :transport_error},
        timestamp: DateTime.utc_now()
      }

      assert [error_occurred, run_failed] = MainCompat.bridge_event(error_event)
      assert error_occurred.type == :error_occurred
      assert run_failed.type == :run_failed

      assert error_occurred.data == %{
               error_code: :transport_error,
               error_message: "boom",
               severity: :error
             }

      assert run_failed.data == %{
               error_code: :transport_error,
               error_message: "boom"
             }
    end
  end
end

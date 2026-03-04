defmodule ASM.V3SurfaceTest do
  use ASM.TestCase

  alias ASM.{Content, Control, Cost, Event, Message, Telemetry, Transport}
  alias ASM.Provider.Claude
  alias ASM.Run.ApprovalCoordinator
  alias ASM.Session.Continuation
  alias ASM.Session.State, as: SessionState
  alias ASM.Test.Factory
  alias ASM.Tool.MCP
  alias ASM.Transport.Test, as: TransportTest

  test "session continuation capture/restore round-trips checkpoint metadata" do
    session_state = SessionState.new("session-v3-surface", Claude.provider(), [])

    checkpoint =
      Continuation.capture(session_state, %{
        run_id: "run-1",
        provider_session_id: "provider-session-1"
      })

    restored = Continuation.restore(session_state, checkpoint)

    assert restored.checkpoint == checkpoint
    assert checkpoint.session_id == "session-v3-surface"
    assert checkpoint.run_id == "run-1"
  end

  test "approval coordinator tracks and resolves approval ownership" do
    approval =
      %Control.ApprovalRequest{
        approval_id: "approval-v3",
        tool_name: "shell",
        tool_input: %{"cmd" => "echo ok"}
      }

    state =
      ApprovalCoordinator.new()
      |> ApprovalCoordinator.register(self(), approval)

    assert {:ok, owner, next_state} = ApprovalCoordinator.resolve(state, approval.approval_id)

    assert owner == self()

    assert {:error, :unknown_approval, ^next_state} =
             ApprovalCoordinator.resolve(next_state, approval.approval_id)
  end

  test "cost computes usage totals via model lookup" do
    update = Cost.from_usage(:claude, "claude-3-5-sonnet", %{input_tokens: 10, output_tokens: 5})

    assert update.input_tokens == 10
    assert update.output_tokens == 5
    assert is_float(update.cost_usd)
    assert update.cost_usd > 0.0
  end

  test "telemetry helper emits run lifecycle events" do
    assert :ok = Telemetry.run_started("session-telemetry", "run-telemetry", :claude)
    assert :ok = Telemetry.run_completed("session-telemetry", "run-telemetry", :claude, :ok)
  end

  test "transport test adapter supports lease-aware demand and message delivery" do
    assert {:ok, transport} = TransportTest.start_link([])
    assert {:ok, :attached} = Transport.attach(transport, self())
    assert :ok = TransportTest.inject(transport, %{"type" => "message", "text" => "ok"})
    assert :ok = Transport.demand(transport, self(), 1)
    assert_receive {:transport_message, %{"type" => "message", "text" => "ok"}}
  end

  test "test factory builds normalized event envelopes" do
    event =
      Factory.event(
        :assistant_message,
        %Message.Assistant{content: [%Content.Text{text: "hello"}]},
        run_id: "run-factory",
        session_id: "session-factory",
        provider: :claude
      )

    assert %Event{} = event
    assert event.kind == :assistant_message
    assert event.run_id == "run-factory"
    assert event.session_id == "session-factory"
    assert event.provider == :claude
  end

  test "mcp tool returns explicit not-configured error by default" do
    assert {:error, :mcp_not_configured} = MCP.call(%{}, %{})
  end
end

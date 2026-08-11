defmodule ASM.Execution.PolicyPlugTest do
  use ASM.TestCase

  alias ASM.Event
  alias ASM.Execution.PolicyPlug
  alias CliSubprocessCore.Payload

  defp tool_event(tool_name) do
    Event.new(
      :tool_use,
      Payload.ToolUse.new(tool_name: tool_name, tool_id: "tool-1", input: %{}),
      run_id: "run-1",
      session_id: "session-1",
      provider: :codex
    )
  end

  test "enforcement_for/1 keys on the capability that means a tool can be refused before it runs" do
    assert PolicyPlug.enforcement_for([:host_tools, :approval]) == :block
    assert PolicyPlug.enforcement_for([:approval, :interrupt]) == :record
    assert PolicyPlug.enforcement_for([:interrupt, :resume, :tools]) == :record
    assert PolicyPlug.enforcement_for([]) == :record
  end

  test "an allowed tool passes untouched regardless of lane" do
    event = tool_event("search")

    assert {:ok, ^event, %{}} =
             PolicyPlug.call(event, %{}, allowed_tools: ["search"], lane_capabilities: [])
  end

  test "an empty allowlist means no policy at all" do
    event = tool_event("TodoWrite")

    assert {:ok, ^event, %{}} =
             PolicyPlug.call(event, %{}, allowed_tools: [], lane_capabilities: [:host_tools])
  end

  test "a host-tool lane blocks a non-matching tool before execution" do
    assert {:error, error, %{}} =
             PolicyPlug.call(tool_event("TodoWrite"), %{},
               allowed_tools: ["search"],
               lane_capabilities: [:host_tools, :approval]
             )

    assert error.kind == :guardrail_blocked
    assert error.message =~ "TodoWrite"
  end

  test "a lane that only observes completed tools records instead of raising" do
    assert {:ok, event, %{}} =
             PolicyPlug.call(tool_event("TodoWrite"), %{},
               allowed_tools: ["search"],
               lane_capabilities: [:interrupt, :resume, :tools]
             )

    assert event.metadata.guardrail == %{
             rule: :allowed_tools,
             action: :recorded,
             reason: :lane_does_not_delegate_tool_execution_to_host,
             tool_name: "TodoWrite",
             allowed_tools: ["search"]
           }
  end

  test "a recorded guardrail is emitted as telemetry for consumers that do not read events" do
    handler_id = "policy-plug-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:asm, :guardrail, :recorded],
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _event, %{}} =
             PolicyPlug.call(tool_event("TodoWrite"), %{},
               allowed_tools: ["search"],
               lane_capabilities: []
             )

    assert_receive {:telemetry, [:asm, :guardrail, :recorded], %{}, metadata}
    assert metadata.tool_name == "TodoWrite"
    assert metadata.allowed_tools == ["search"]
    assert metadata.run_id == "run-1"
  end

  test "no lane capabilities option records instead of claiming enforcement" do
    assert {:ok, event, %{}} =
             PolicyPlug.call(tool_event("TodoWrite"), %{}, allowed_tools: ["search"])

    assert event.metadata.guardrail.action == :recorded
  end

  test "events other than tool_use are untouched" do
    event =
      Event.new(:assistant_delta, Payload.AssistantDelta.new(content: "hi"),
        run_id: "run-1",
        session_id: "session-1",
        provider: :codex
      )

    assert {:ok, ^event, %{}} =
             PolicyPlug.call(event, %{}, allowed_tools: ["search"], lane_capabilities: [])
  end
end

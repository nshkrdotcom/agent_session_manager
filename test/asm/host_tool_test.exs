defmodule ASM.HostToolTest do
  use ASM.TestCase

  alias ASM.{Event, HostTool}

  test "host tool specs normalize to Codex dynamic tool wire specs without leaking wire keys" do
    assert {:ok, spec} =
             HostTool.Spec.new(
               name: "echo_json",
               description: "Echo JSON arguments",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"]
               },
               output_schema: %{"type" => "object"},
               metadata: %{owner: :test}
             )

    assert spec.name == "echo_json"
    assert spec.input_schema["type"] == "object"
    assert spec.metadata == %{owner: :test}

    assert HostTool.Spec.to_dynamic_tool(spec) == %{
             "name" => "echo_json",
             "description" => "Echo JSON arguments",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{"message" => %{"type" => "string"}},
               "required" => ["message"]
             },
             "outputSchema" => %{"type" => "object"}
           }
  end

  test "host tool request and response payloads are valid ASM event payloads" do
    request =
      HostTool.Request.new!(
        id: "jsonrpc-1",
        session_id: "session-1",
        run_id: "run-1",
        provider: :codex,
        provider_session_id: "thread-1",
        provider_turn_id: "turn-1",
        tool_name: "echo_json",
        arguments: %{"message" => "hello"},
        raw: %{codex_request_id: "jsonrpc-1"},
        metadata: %{call_id: "call-1"}
      )

    event =
      Event.new(:host_tool_requested, request,
        run_id: "run-1",
        session_id: "session-1",
        provider: :codex,
        provider_session_id: "thread-1",
        metadata: %{provider_turn_id: "turn-1", tool_name: "echo_json"}
      )

    assert event.kind == :host_tool_requested
    assert event.payload == request
    assert :host_tool_requested in Event.kinds()

    response =
      HostTool.Response.new!(
        request_id: request.id,
        success?: true,
        output: %{"echo" => request.arguments},
        content_items: [%{"type" => "inputText", "text" => "ok"}],
        metadata: %{call_id: "call-1"}
      )

    completed =
      Event.new(:host_tool_completed, response,
        run_id: "run-1",
        session_id: "session-1",
        provider: :codex,
        provider_session_id: "thread-1"
      )

    assert completed.kind == :host_tool_completed
    assert completed.payload == response
    assert :host_tool_completed in Event.kinds()

    assert HostTool.Response.to_dynamic_tool_response(response) == %{
             "success" => true,
             "output" => Jason.encode!(%{"echo" => %{"message" => "hello"}}),
             "contentItems" => [%{"type" => "inputText", "text" => "ok"}]
           }
  end
end

defmodule ASM.JidoHarness.DriverTest do
  use ASM.TestCase

  alias ASM.TestSupport.StreamScriptedDriver

  alias Jido.Harness.{
    ExecutionEvent,
    ExecutionResult,
    RunHandle,
    RunRequest,
    RuntimeDescriptor
  }

  test "runtime_descriptor/1 reports provider-aware capabilities truthfully" do
    descriptor = ASM.JidoHarness.Driver.runtime_descriptor(provider: :claude)

    assert %RuntimeDescriptor{} = descriptor
    assert descriptor.runtime_id == :asm
    assert descriptor.provider == :claude
    assert descriptor.streaming?
    assert descriptor.cancellation?
    assert descriptor.approvals?
    assert descriptor.cost?
    assert descriptor.resume?
    refute descriptor.subscribe?
  end

  test "provider adapters keep optional cli path env vars forwardable but not required" do
    contract = ASM.JidoHarness.ClaudeAdapter.runtime_contract()

    assert contract.host_env_required_any == []
    assert contract.host_env_required_all == []
    assert contract.sprite_env_forward == ["CLAUDE_CLI_PATH"]
  end

  test "stream_run/3 maps asm envelopes to harness execution events" do
    assert {:ok, session} = ASM.JidoHarness.Driver.start_session(provider: :claude)

    on_exit(fn ->
      _ = ASM.JidoHarness.Driver.stop_session(session)
    end)

    request = RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:ok, run, stream} =
             ASM.JidoHarness.Driver.stream_run(session, request,
               driver: StreamScriptedDriver,
               run_id: "bridge-run-1"
             )

    assert %RunHandle{run_id: "bridge-run-1", runtime_id: :asm, provider: :claude} = run

    events = Enum.to_list(stream)

    assert [
             %ExecutionEvent{type: :run_started, provider: :claude},
             %ExecutionEvent{
               type: :assistant_delta,
               provider: :claude,
               payload: %{"content_type" => "text", "delta" => "hello "}
             },
             %ExecutionEvent{
               type: :assistant_delta,
               provider: :claude,
               payload: %{"content_type" => "text", "delta" => "from scripted driver"}
             },
             %ExecutionEvent{type: :result, provider: :claude}
           ] = events
  end

  test "run/3 maps asm results to harness execution results" do
    assert {:ok, session} = ASM.JidoHarness.Driver.start_session(provider: :claude)

    on_exit(fn ->
      _ = ASM.JidoHarness.Driver.stop_session(session)
    end)

    request = RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:ok, result} =
             ASM.JidoHarness.Driver.run(session, request,
               driver: StreamScriptedDriver,
               run_id: "bridge-run-2"
             )

    assert %ExecutionResult{} = result
    assert result.runtime_id == :asm
    assert result.provider == :claude
    assert result.run_id == "bridge-run-2"
    assert result.status == :completed
    assert result.text == "hello from scripted driver"
    assert result.stop_reason == "end_turn"
  end

  test "run/3 maps cancelled asm results to cancelled execution results" do
    assert {:ok, session} = ASM.JidoHarness.Driver.start_session(provider: :claude)

    on_exit(fn ->
      _ = ASM.JidoHarness.Driver.stop_session(session)
    end)

    request = RunRequest.new!(%{prompt: "hello", metadata: %{}})

    assert {:ok, result} =
             ASM.JidoHarness.Driver.run(session, request,
               driver: StreamScriptedDriver,
               run_id: "bridge-run-3",
               driver_opts: [
                 script: [
                   {:assistant_delta,
                    %ASM.Message.Partial{content_type: :text, delta: "partial"}},
                   {:error,
                    %ASM.Message.Error{
                      severity: :warning,
                      message: "Run interrupted",
                      kind: :user_cancelled
                    }}
                 ]
               ]
             )

    assert %ExecutionResult{} = result
    assert result.run_id == "bridge-run-3"
    assert result.status == :cancelled
    assert result.error["kind"] == "user_cancelled"
    assert result.error["message"] == "Run interrupted"
  end
end

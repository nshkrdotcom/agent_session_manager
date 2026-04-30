defmodule ASM.APITest do
  use ASM.TestCase

  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload.{AssistantDelta, Error, Result, RunStarted, ToolUse}

  test "start_link/1 starts a session server for OTP-style usage" do
    session_id = "api-start-link-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_link(session_id: session_id, provider: :claude)
    assert is_pid(session)
    assert ASM.session_id(session) == session_id

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 with session pid returns a projected result from the backend runtime" do
    session_id = "api-session-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:ok, result} =
             ASM.query(session, "hello", backend_module: FakeBackend)

    assert result.session_id == session_id
    assert result.text == "hello"

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 with provider atom uses ephemeral session and tears it down" do
    session_id = "api-ephemeral-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, result} =
             ASM.query(:claude, "hello",
               session_id: session_id,
               backend_module: FakeBackend
             )

    assert result.session_id == session_id

    assert_eventually(fn ->
      Registry.lookup(:asm_sessions, {session_id, :subtree}) == []
    end)
  end

  test "query/3 rejects provider option mismatches instead of overwriting them" do
    assert {:error, error} =
             ASM.query(:gemini, "hello",
               provider: :claude,
               backend_module: FakeBackend
             )

    assert error.kind == :config_invalid
    assert %ASM.Options.ProviderMismatchError{} = error.cause
    assert error.cause.expected_provider == :gemini
    assert error.cause.actual_provider == :claude
  end

  test "query/3 rejects redundant provider options for positional provider calls" do
    assert {:error, error} =
             ASM.query(:gemini, "hello",
               provider: :gemini,
               backend_module: FakeBackend
             )

    assert error.kind == :config_invalid
    assert %ASM.Options.ProviderMismatchError{} = error.cause
    assert error.cause.reason == :redundant_provider
    assert error.cause.expected_provider == :gemini
    assert error.cause.actual_provider == :gemini
  end

  test "session-level provider options are inherited by stream/query calls" do
    session_id = "api-options-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :claude,
               model: "sonnet"
             )

    events =
      ASM.stream(session, "hello", backend_module: FakeBackend)
      |> Enum.to_list()

    assert ASM.Stream.final_result(events).text == "sonnet"

    assert :ok = ASM.stop_session(session)
  end

  test "session_info/1 returns normalized kernel session metadata" do
    session_id = "api-session-info-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :claude,
               cwd: "/tmp/asm-session-info",
               permission_mode: :plan,
               model: "sonnet"
             )

    assert {:ok, info} = ASM.session_info(session)
    assert info.session_id == session_id
    assert info.provider == :claude
    assert info.status == :ready
    assert info.options[:cwd] == "/tmp/asm-session-info"
    assert info.options[:permission_mode] == :plan
    assert info.options[:model] == "sonnet"

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 surfaces terminal run errors as {:error, %ASM.Error{}}" do
    session_id = "api-query-error-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    error_script = [
      {:core, :run_started, RunStarted.new(command: "fake")},
      {:core, :error, Error.new(message: "nope", code: "tool_failed")}
    ]

    assert {:error, error} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [script: error_script]
             )

    assert error.kind == :tool_failed
    assert error.domain == :runtime
    assert error.message =~ "nope"

    assert :ok = ASM.stop_session(session)
  end

  test "cost/1 reflects cumulative usage from completed runs" do
    session_id = "api-cost-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    result_script = [
      {:core, :run_started, RunStarted.new(command: "fake")},
      {:core, :assistant_delta, AssistantDelta.new(content: "hi")},
      {:core, :result,
       Result.new(
         status: :completed,
         stop_reason: :end_turn,
         output: %{usage: %{input_tokens: 2, output_tokens: 3}}
       )}
    ]

    assert {:ok, result} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [script: result_script],
               pipeline: [{ASM.Pipeline.CostTracker, input_rate: 0.1, output_rate: 0.2}]
             )

    assert result.text == "hi"
    assert result.cost == %{input_tokens: 2, output_tokens: 3, cost_usd: 0.8}

    cost = ASM.cost(session)
    assert cost == %{input_tokens: 2, output_tokens: 3, cost_usd: 0.8}

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 blocks tool_use events outside a non-empty allowed_tools list" do
    session_id = "api-allowlist-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :claude,
               allowed_tools: ["search"]
             )

    on_exit(fn ->
      _ = ASM.stop_session(session)
    end)

    script = [
      {:core, :run_started, RunStarted.new(command: "fake")},
      {:core, :tool_use,
       ToolUse.new(tool_name: "bash", tool_id: "tool-1", input: %{"cmd" => "pwd"})}
    ]

    assert {:error, error} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [script: script]
             )

    assert error.kind == :guardrail_blocked
    assert error.domain == :guardrail
    assert error.message =~ "bash"
  end

  test "health/1 and cost/1 reflect session process status" do
    session_id = "api-health-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert ASM.health(session) == :healthy
    assert ASM.health(session_id) == :healthy
    cost = ASM.cost(session)
    assert cost.input_tokens == 0
    assert cost.output_tokens == 0
    assert is_float(cost.cost_usd)

    assert :ok = ASM.stop_session(session)
    assert {:ok, _reason} = wait_for_process_death(session, 2_000)
    assert_eventually(fn -> ASM.health(session_id) == {:unhealthy, :not_found} end)
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0) do
    assert fun.()
  end
end

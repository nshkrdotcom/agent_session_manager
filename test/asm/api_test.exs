defmodule ASM.APITest do
  use ASM.TestCase

  alias ASM.Message

  defmodule OptionProbeDriver do
    @moduledoc false

    alias ASM.{Event, Message, Run}

    @spec start(map()) :: {:ok, pid()}
    def start(%{} = context) do
      {:ok, spawn(fn -> emit(context) end)}
    end

    defp emit(context) do
      model = to_string(Keyword.get(context.provider_opts, :model, "missing-model"))

      Run.Server.ingest_event(
        context.run_pid,
        %Event{
          id: Event.generate_id(),
          kind: :assistant_delta,
          run_id: context.run_id,
          session_id: context.session_id,
          provider: context.provider,
          payload: %Message.Partial{content_type: :text, delta: model},
          timestamp: DateTime.utc_now()
        }
      )

      Run.Server.ingest_event(
        context.run_pid,
        %Event{
          id: Event.generate_id(),
          kind: :result,
          run_id: context.run_id,
          session_id: context.session_id,
          provider: context.provider,
          payload: %Message.Result{stop_reason: :end_turn},
          timestamp: DateTime.utc_now()
        }
      )
    end
  end

  test "start_link/1 starts a session server for OTP-style usage" do
    session_id = "api-start-link-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_link(session_id: session_id, provider: :claude)
    assert is_pid(session)
    assert ASM.session_id(session) == session_id

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 with session pid returns a projected result" do
    session_id = "api-session-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:ok, result} =
             ASM.query(session, "hello", driver: ASM.TestSupport.StreamScriptedDriver)

    assert result.session_id == session_id
    assert result.text == "hello from scripted driver"

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 with provider atom uses ephemeral session and tears it down" do
    session_id = "api-ephemeral-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, result} =
             ASM.query(:claude, "hello",
               session_id: session_id,
               driver: ASM.TestSupport.StreamScriptedDriver
             )

    assert result.session_id == session_id

    assert_eventually(fn ->
      Registry.lookup(:asm_sessions, {session_id, :subtree}) == []
    end)
  end

  test "session-level provider options are inherited by stream/query calls" do
    session_id = "api-options-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :claude,
               model: "session-default-model"
             )

    events =
      ASM.stream(session, "hello", driver: OptionProbeDriver)
      |> Enum.to_list()

    assert ASM.Stream.final_result(events).text == "session-default-model"

    assert :ok = ASM.stop_session(session)
  end

  test "query/3 surfaces terminal run errors as {:error, %ASM.Error{}}" do
    session_id = "api-query-error-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:error, error} =
             ASM.query(session, "hello",
               driver: ASM.TestSupport.StreamScriptedDriver,
               driver_opts: [
                 script: [
                   {:error,
                    %Message.Error{
                      severity: :error,
                      message: "nope",
                      kind: :tool_failed
                    }}
                 ]
               ]
             )

    assert error.kind == :tool_failed
    assert error.domain == :runtime
    assert error.message =~ "nope"

    assert :ok = ASM.stop_session(session)
  end

  test "cost/1 reflects cumulative usage from completed runs" do
    session_id = "api-cost-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:ok, result} =
             ASM.query(session, "hello",
               driver: ASM.TestSupport.StreamScriptedDriver,
               pipeline: [{ASM.Pipeline.CostTracker, input_rate: 0.1, output_rate: 0.2}],
               driver_opts: [
                 script: [
                   {:assistant_delta, %Message.Partial{content_type: :text, delta: "hi"}},
                   {:result,
                    %Message.Result{
                      stop_reason: :end_turn,
                      usage: %{input_tokens: 2, output_tokens: 3}
                    }}
                 ]
               ]
             )

    assert result.text == "hi"
    assert result.cost == %{input_tokens: 2, output_tokens: 3, cost_usd: 0.8}

    cost = ASM.cost(session)
    assert cost == %{input_tokens: 2, output_tokens: 3, cost_usd: 0.8}

    assert :ok = ASM.stop_session(session)
  end

  test "stop_session/1 accepts a session server pid" do
    session_id = "api-stop-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert :ok = ASM.stop_session(session)
    assert {:ok, _reason} = wait_for_process_death(session, 2_000)
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

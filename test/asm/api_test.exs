defmodule ASM.APITest do
  use ExUnit.Case, async: true

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

  test "stop_session/1 accepts a session server pid" do
    session_id = "api-stop-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert :ok = ASM.stop_session(session)

    assert_eventually(fn ->
      not Process.alive?(session)
    end)
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

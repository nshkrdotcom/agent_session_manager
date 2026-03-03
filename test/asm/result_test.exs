defmodule ASM.ResultTest do
  use ExUnit.Case, async: true

  alias ASM.Result

  test "result requires run and session ids" do
    assert_raise ArgumentError, fn -> struct!(Result, %{}) end

    result = struct!(Result, %{run_id: "run-1", session_id: "session-1"})

    assert result.run_id == "run-1"
    assert result.session_id == "session-1"
    assert result.text == nil
    assert result.cost == nil
    assert result.error == nil
  end
end

defmodule AgentSessionManager.Examples.LiveSessionExampleTest do
  use ExUnit.Case, async: true

  setup_all do
    unless Code.ensure_loaded?(LiveSession) do
      {_, _binding} =
        Code.eval_string(
          File.read!("examples/live_session.exs")
          |> String.replace(~r/^LiveSession\.main\(System\.argv\(\)\)$/m, ":ok"),
          [],
          file: "examples/live_session.exs"
        )
    end

    :ok
  end

  test "maps provider strings to model lookup without raising" do
    assert LiveSession.default_model_for_provider("claude") ==
             AgentSessionManager.Models.default_model(:claude)

    assert LiveSession.default_model_for_provider("codex") ==
             AgentSessionManager.Models.default_model(:codex)

    assert LiveSession.default_model_for_provider("amp") ==
             AgentSessionManager.Models.default_model(:amp)
  end
end

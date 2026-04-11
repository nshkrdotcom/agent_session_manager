defmodule ASM.Run.EventReducerTest do
  use ASM.TestCase, async: true

  alias ASM.{Event, Run}
  alias ASM.Run.EventReducer
  alias CliSubprocessCore.Payload

  test "error payload recovery metadata is preserved on ASM.Error" do
    state = Run.State.new(run_id: "run-1", session_id: "session-1", provider: :claude)

    event =
      Event.new(
        :error,
        Payload.Error.new(
          message: "Authentication failed",
          code: "auth_error",
          severity: :fatal,
          metadata: %{
            "recovery" => %{
              "class" => "provider_auth_claim",
              "retryable?" => true
            }
          }
        ),
        run_id: "run-1",
        session_id: "session-1",
        provider: :claude,
        timestamp: DateTime.utc_now()
      )

    next_state = EventReducer.apply_event!(state, event)

    assert next_state.status == :failed
    assert next_state.error.retryable == true
    assert next_state.error.recovery["class"] == "provider_auth_claim"
  end
end

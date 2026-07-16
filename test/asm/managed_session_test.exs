defmodule ASM.ManagedSessionTest do
  use ExUnit.Case, async: true

  alias ASM.ManagedSession
  alias ASM.ManagedSession.Lifecycle

  defp allocated do
    ManagedSession.new!(
      session_ref: "session://asm/codex/run-1/generation-1",
      generation: 1,
      provider_account_ref: "account://codex/acme-primary",
      credential_generation: 7,
      materialization_ref: "materialization://jido/codex/run-1",
      authority_ref: "grant://citadel/codex/run-1",
      target_ref: "target://nshkr/local-process",
      runtime_gateway: "gateway://cli-subprocess-core/local",
      status: :allocated,
      fence: 11,
      row_version: 1
    )
  end

  test "managed identity rejects process handles, secret fields, and absolute paths" do
    session = allocated()
    refute is_pid(session.session_ref)

    assert {:error, :invalid_managed_session} =
             session |> Map.from_struct() |> Map.put(:session_ref, self()) |> ManagedSession.new()

    assert {:error, :invalid_managed_session} =
             session
             |> Map.from_struct()
             |> Map.put(:token, "sentinel-secret")
             |> ManagedSession.new()

    assert {:error, :invalid_managed_session} =
             session
             |> Map.from_struct()
             |> Map.put(:materialization_ref, "/tmp/ambient-codex-home")
             |> ManagedSession.new()
  end

  test "lifecycle requires optimistic revision and opaque execution identity" do
    assert {:ok, starting} =
             Lifecycle.transition(allocated(), :starting, expected_row_version: 1)

    assert {:error, :invalid_managed_session_transition} =
             Lifecycle.transition(starting, :active, expected_row_version: 1)

    assert {:error, :invalid_managed_session_transition} =
             Lifecycle.transition(starting, :active, expected_row_version: 2)

    assert {:ok, active} =
             Lifecycle.transition(starting, :active,
               expected_row_version: 2,
               execution_ref: "execution://cli-core/codex/run-1",
               provider_session_ref: "provider-session://codex/run-1"
             )

    assert active.row_version == 3
  end

  test "terminal state requires a lower receipt and cannot be reopened" do
    active =
      allocated()
      |> Lifecycle.transition(:starting, expected_row_version: 1)
      |> elem(1)
      |> Lifecycle.transition(:active,
        expected_row_version: 2,
        execution_ref: "execution://cli-core/codex/run-1"
      )
      |> elem(1)

    assert {:error, :invalid_managed_session_transition} =
             Lifecycle.transition(active, :completed, expected_row_version: 3)

    assert {:ok, completed} =
             Lifecycle.transition(active, :completed,
               expected_row_version: 3,
               receipt_ref: "receipt://cli-core/codex/run-1"
             )

    assert ManagedSession.terminal?(completed)

    assert {:error, :invalid_managed_session_transition} =
             Lifecycle.transition(completed, :active,
               expected_row_version: 4,
               receipt_ref: nil
             )
  end
end

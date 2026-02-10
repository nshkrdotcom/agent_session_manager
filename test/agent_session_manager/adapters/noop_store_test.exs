defmodule AgentSessionManager.Adapters.NoopStoreTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.NoopStore
  alias AgentSessionManager.Core.Error

  test "flush/2 succeeds as a no-op" do
    assert :ok =
             NoopStore.flush(NoopStore, %{
               session: %{},
               run: %{},
               events: [],
               provider_metadata: %{}
             })
  end

  test "load_run/2 and load_session/2 return not_found errors" do
    assert {:error, %Error{code: :not_found}} = NoopStore.load_run(NoopStore, "run_missing")
    assert {:error, %Error{code: :not_found}} = NoopStore.load_session(NoopStore, "ses_missing")
  end

  test "load_events/3 returns empty list" do
    assert {:ok, []} = NoopStore.load_events(NoopStore, "ses_missing", [])
  end
end

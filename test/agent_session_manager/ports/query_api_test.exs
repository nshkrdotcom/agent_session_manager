defmodule AgentSessionManager.Ports.QueryAPITest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.QueryAPI

  defmodule DummyQuery do
    def search_sessions(_ctx, _opts), do: {:ok, %{sessions: [], cursor: nil, total_count: 0}}
    def get_session_stats(_ctx, _session_id), do: {:ok, %{}}
    def search_runs(_ctx, _opts), do: {:ok, %{runs: [], cursor: nil}}
    def get_usage_summary(_ctx, _opts), do: {:ok, %{}}
    def search_events(_ctx, _opts), do: {:ok, %{events: [], cursor: nil}}
    def count_events(_ctx, _opts), do: {:ok, 0}
    def export_session(_ctx, _session_id, _opts), do: {:ok, %{}}
  end

  test "dispatches module-backed refs" do
    assert {:ok, %{sessions: [], cursor: nil, total_count: 0}} =
             QueryAPI.search_sessions({DummyQuery, :ctx})
  end

  test "rejects non-module query refs" do
    assert {:error, %Error{code: :validation_error}} = QueryAPI.search_sessions(self())
  end
end

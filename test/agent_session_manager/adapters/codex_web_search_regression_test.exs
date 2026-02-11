defmodule AgentSessionManager.Adapters.CodexWebSearchRegressionTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Adapters.CodexAdapter
  alias AgentSessionManager.Core.{Run, Session}
  alias Codex.Events
  alias Codex.Items

  defmodule WebSearchItemMockSDK do
    def run_streamed(_sdk_pid, _thread, _input, _opts) do
      events = [
        %Events.ThreadStarted{thread_id: "thread-ws", metadata: %{}},
        %Events.TurnStarted{thread_id: "thread-ws", turn_id: "turn-ws"},
        %Events.ItemCompleted{
          thread_id: "thread-ws",
          turn_id: "turn-ws",
          item: %Items.WebSearch{id: "search_1", query: ""}
        },
        %Events.TurnCompleted{
          thread_id: "thread-ws",
          turn_id: "turn-ws",
          status: "completed",
          usage: %{"input_tokens" => 1, "output_tokens" => 1}
        }
      ]

      {:ok, %{raw_events_fn: fn -> events end}}
    end

    def raw_events(%{raw_events_fn: fun}), do: fun.()
    def cancel(_sdk_pid), do: :ok
  end

  test "CodexAdapter handles WebSearch item structs without crashing" do
    {:ok, adapter} =
      CodexAdapter.start_link(
        working_directory: "/tmp/test",
        sdk_module: WebSearchItemMockSDK,
        sdk_pid: self()
      )

    on_exit(fn ->
      if Process.alive?(adapter), do: CodexAdapter.stop(adapter)
    end)

    {:ok, session} = Session.new(%{agent_id: "regression"})

    {:ok, run} =
      Run.new(%{session_id: session.id, input: %{messages: [%{role: "user", content: "search"}]}})

    assert {:ok, result} = CodexAdapter.execute(adapter, run, session, timeout: 5_000)

    assert is_list(result.output.tool_calls)

    assert Enum.any?(result.output.tool_calls, fn tool_call ->
             tool_call.id == "search_1" and tool_call.name == "web_search"
           end)
  end
end

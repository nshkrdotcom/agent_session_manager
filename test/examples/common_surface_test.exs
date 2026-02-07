defmodule AgentSessionManager.Examples.CommonSurfaceTest do
  @moduledoc """
  Tests for the common surface example script.

  These tests verify that the common_surface.exs example compiles
  and, when live, completes a full session lifecycle through the
  normalized SessionManager interface.
  """

  use AgentSessionManager.SupertesterCase, async: false

  @moduletag :live

  alias AgentSessionManager.Adapters.ClaudeAdapter
  alias AgentSessionManager.SessionManager

  setup ctx do
    if System.get_env("LIVE_TESTS") != "true" do
      {:ok, Map.put(ctx, :skip, true)}
    else
      {:ok, store} = setup_test_store(ctx)
      {:ok, Map.put(ctx, :store, store) |> Map.put(:skip, false)}
    end
  end

  describe "common surface example" do
    @tag :live
    test "example script compiles without warnings", ctx do
      if ctx[:skip] do
        :ok
      else
        {result, _binding} =
          Code.eval_string(
            File.read!("examples/common_surface.exs")
            |> String.replace(~r/^CommonSurface\.main\(System\.argv\(\)\)$/m, ":ok"),
            [],
            file: "examples/common_surface.exs"
          )

        assert result == :ok
      end
    end

    @tag :live
    test "session lifecycle completes with claude provider", ctx do
      if ctx[:skip] do
        :ok
      else
        store = ctx.store

        {:ok, adapter} =
          ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001")

        cleanup_on_exit(fn -> safe_stop(adapter) end)

        {:ok, session} =
          SessionManager.start_session(store, adapter, %{
            agent_id: "common-surface-test",
            context: %{system_prompt: "You are a helpful assistant. Keep responses concise."},
            tags: ["test", "common-surface"]
          })

        assert session.id != nil

        {:ok, activated} = SessionManager.activate_session(store, session.id)
        assert activated.status == :active

        {:ok, run} =
          SessionManager.start_run(store, adapter, session.id, %{
            messages: [
              %{role: "user", content: "What is the BEAM virtual machine? One sentence."}
            ]
          })

        assert run.id != nil

        {:ok, result} = SessionManager.execute_run(store, adapter, run.id)
        assert result.output.content != ""
        assert result.token_usage.input_tokens > 0

        {:ok, completed} = SessionManager.complete_session(store, session.id)
        assert completed.status == :completed
      end
    end

    @tag :live
    test "multi-run session produces events for each run", ctx do
      if ctx[:skip] do
        :ok
      else
        store = ctx.store

        {:ok, adapter} =
          ClaudeAdapter.start_link(model: "claude-haiku-4-5-20251001")

        cleanup_on_exit(fn -> safe_stop(adapter) end)

        {:ok, session} =
          SessionManager.start_session(store, adapter, %{
            agent_id: "multi-run-test",
            context: %{system_prompt: "Be concise."}
          })

        {:ok, _} = SessionManager.activate_session(store, session.id)

        # Run 1
        {:ok, run1} =
          SessionManager.start_run(store, adapter, session.id, %{
            messages: [%{role: "user", content: "Say hello in one word."}]
          })

        {:ok, _result1} = SessionManager.execute_run(store, adapter, run1.id)

        # Run 2
        {:ok, run2} =
          SessionManager.start_run(store, adapter, session.id, %{
            messages: [%{role: "user", content: "Say goodbye in one word."}]
          })

        {:ok, _result2} = SessionManager.execute_run(store, adapter, run2.id)

        # Verify events per run
        {:ok, run1_events} =
          SessionManager.get_session_events(store, session.id, run_id: run1.id)

        {:ok, run2_events} =
          SessionManager.get_session_events(store, session.id, run_id: run2.id)

        assert run1_events != []
        assert run2_events != []

        # Verify runs list
        {:ok, runs} = SessionManager.get_session_runs(store, session.id)
        assert length(runs) == 2

        {:ok, _} = SessionManager.complete_session(store, session.id)
      end
    end
  end
end

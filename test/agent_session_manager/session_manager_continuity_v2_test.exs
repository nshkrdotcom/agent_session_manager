defmodule AgentSessionManager.SessionManagerContinuityV2Test do
  @moduledoc """
  Tests for Phase 2 Session Continuity v2 features:
  - continuation modes (:auto, :native, :replay)
  - per-provider continuation handles (provider_sessions)
  - current-only continuation options (boolean continuation rejected)
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  # ============================================================================
  # Mock Adapter with provider name "mock-provider"
  # ============================================================================

  defmodule ContinuityMockAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.Core.Capability

    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(opts), do: {:ok, %{opts: opts}}

    @impl GenServer
    def handle_call(:name, _from, state), do: {:reply, "mock-provider", state}

    @impl GenServer
    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}, state}
    end

    @impl GenServer
    def handle_call({:execute, run, _session, opts}, _from, state) do
      callback = Keyword.get(opts, :event_callback)

      if callback do
        callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{
            provider_session_id: "mock-ses-abc",
            model: "mock-model-v2"
          },
          timestamp: DateTime.utc_now()
        })

        callback.(%{
          type: :message_received,
          session_id: run.session_id,
          run_id: run.id,
          data: %{content: "response", role: "assistant"},
          timestamp: DateTime.utc_now()
        })

        callback.(%{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: DateTime.utc_now()
        })
      end

      {:reply,
       {:ok,
        %{
          output: %{content: "response"},
          token_usage: %{input_tokens: 5, output_tokens: 10},
          events: []
        }}, state}
    end

    @impl GenServer
    def handle_call({:cancel, run_id}, _from, state) do
      {:reply, {:ok, run_id}, state}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(adapter), do: GenServer.call(adapter, :name)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id), do: GenServer.call(adapter, {:cancel, run_id})

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_adapter, _config), do: :ok
  end

  setup ctx do
    {:ok, store} = setup_test_store(ctx)
    {:ok, adapter} = ContinuityMockAdapter.start_link()
    cleanup_on_exit(fn -> safe_stop(adapter) end)

    {:ok, session} =
      SessionManager.start_session(store, adapter, %{agent_id: "continuity-v2-test"})

    {:ok, _} = SessionManager.activate_session(store, session.id)

    %{store: store, adapter: adapter, session: session}
  end

  describe "continuation mode parsing" do
    test "continuation: true is rejected", ctx do
      # First run to generate events
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run1.id)

      {:ok, run2} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "again"}]
        })

      assert {:error, %Error{code: :validation_error}} =
               SessionManager.execute_run(ctx.store, ctx.adapter, run2.id, continuation: true)
    end

    test "continuation: :auto is accepted and injects transcript", ctx do
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run1.id)

      {:ok, run2} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "again"}]
        })

      {:ok, _} =
        SessionManager.execute_run(ctx.store, ctx.adapter, run2.id, continuation: :auto)
    end

    test "continuation: :replay forces transcript replay", ctx do
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run1.id)

      {:ok, run2} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "again"}]
        })

      {:ok, _} =
        SessionManager.execute_run(ctx.store, ctx.adapter, run2.id, continuation: :replay)
    end

    test "continuation: :native returns error when native is unavailable", ctx do
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run1.id)

      {:ok, run2} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "again"}]
        })

      # None of the mock adapters support native continuation, so :native should error
      assert {:error, %Error{code: :invalid_operation}} =
               SessionManager.execute_run(ctx.store, ctx.adapter, run2.id, continuation: :native)
    end

    test "continuation: false disables continuation (default)", ctx do
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} =
        SessionManager.execute_run(ctx.store, ctx.adapter, run1.id, continuation: false)
    end
  end

  describe "provider_sessions metadata" do
    test "stores per-provider continuation handle after execution", ctx do
      {:ok, run} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run.id)

      {:ok, session} = SessionStore.get_session(ctx.store, ctx.session.id)

      assert is_map(session.metadata[:provider_sessions])
      refute Map.has_key?(session.metadata, :provider_session_id)
      refute Map.has_key?(session.metadata, :model)

      assert session.metadata[:provider_sessions]["mock-provider"][:provider_session_id] ==
               "mock-ses-abc"

      assert session.metadata[:provider_sessions]["mock-provider"][:model] == "mock-model-v2"
    end

    test "accumulates provider_sessions across multiple providers", ctx do
      {:ok, run1} =
        SessionManager.start_run(ctx.store, ctx.adapter, ctx.session.id, %{
          messages: [%{role: "user", content: "hello"}]
        })

      {:ok, _} = SessionManager.execute_run(ctx.store, ctx.adapter, run1.id)

      {:ok, session} = SessionStore.get_session(ctx.store, ctx.session.id)
      assert Map.has_key?(session.metadata[:provider_sessions], "mock-provider")
    end
  end
end

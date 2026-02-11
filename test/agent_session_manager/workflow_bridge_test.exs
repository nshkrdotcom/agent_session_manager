defmodule AgentSessionManager.WorkflowBridgeTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Core.{Error, Transcript}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.WorkflowBridge
  alias AgentSessionManager.WorkflowBridge.{ErrorClassification, StepResult}

  defmodule BridgeMockAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.Core.Capability

    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(_opts) do
      {:ok, %{last_execute_opts: [], last_execute_session: nil}}
    end

    @impl GenServer
    def handle_call(:name, _from, state), do: {:reply, "bridge-mock", state}

    def handle_call(:capabilities, _from, state) do
      capabilities = [%Capability{name: "chat", type: :tool, enabled: true}]
      {:reply, {:ok, capabilities}, state}
    end

    def handle_call({:execute, run, session, opts}, _from, state) do
      callback = Keyword.get(opts, :event_callback)
      message = extract_first_message(run.input)

      output =
        if String.contains?(message, "tool") do
          %{
            content: "tool-needed",
            stop_reason: "tool_use",
            tool_calls: [%{id: "tool_1", name: "search", input: %{query: "q"}}]
          }
        else
          %{
            content: "ack: #{message}",
            stop_reason: "end_turn",
            tool_calls: []
          }
        end

      events = [
        %{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: DateTime.utc_now()
        },
        %{
          type: :message_received,
          session_id: run.session_id,
          run_id: run.id,
          data: %{content: output.content, role: "assistant"},
          timestamp: DateTime.utc_now()
        },
        %{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{stop_reason: output.stop_reason},
          timestamp: DateTime.utc_now()
        }
      ]

      if is_function(callback, 1), do: Enum.each(events, callback)

      {:reply,
       {:ok,
        %{
          output: output,
          token_usage: %{input_tokens: 3, output_tokens: 5},
          events: events
        }}, %{state | last_execute_opts: opts, last_execute_session: session}}
    end

    def handle_call({:cancel, run_id}, _from, state), do: {:reply, {:ok, run_id}, state}
    def handle_call({:validate_config, _config}, _from, state), do: {:reply, :ok, state}

    def handle_call(:get_last_execute_opts, _from, state),
      do: {:reply, state.last_execute_opts, state}

    def handle_call(:get_last_execute_session, _from, state),
      do: {:reply, state.last_execute_session, state}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(adapter), do: GenServer.call(adapter, :name)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []),
      do: GenServer.call(adapter, {:execute, run, session, opts})

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id), do: GenServer.call(adapter, {:cancel, run_id})

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(adapter, config), do: GenServer.call(adapter, {:validate_config, config})

    def get_last_execute_opts(adapter), do: GenServer.call(adapter, :get_last_execute_opts)
    def get_last_execute_session(adapter), do: GenServer.call(adapter, :get_last_execute_session)

    defp extract_first_message(%{messages: [%{content: content} | _]}) when is_binary(content),
      do: content

    defp extract_first_message(%{"messages" => [%{"content" => content} | _]})
         when is_binary(content),
         do: content

    defp extract_first_message(_), do: "hello"
  end

  setup do
    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, adapter} = BridgeMockAdapter.start_link([])
    %{store: store, adapter: adapter, module_backed_store: {InMemorySessionStore, store}}
  end

  describe "step_execute/3 one-shot mode" do
    test "executes with GenServer-backed store", %{store: store, adapter: adapter} do
      assert {:ok, %StepResult{} = result} =
               WorkflowBridge.step_execute(store, adapter, %{
                 input: %{messages: [%{role: "user", content: "hello"}]}
               })

      assert is_binary(result.session_id)
      assert is_binary(result.run_id)
      assert result.content == "ack: hello"
      assert result.stop_reason == "end_turn"
      assert result.has_tool_calls == false
      assert result.tool_calls == []
      assert result.token_usage == %{input_tokens: 3, output_tokens: 5}
      assert is_list(result.events)
      assert result.retryable == false
    end

    test "executes with module-backed tuple store via multi-step fallback", %{
      module_backed_store: module_backed_store,
      adapter: adapter
    } do
      assert {:ok, %StepResult{} = result} =
               WorkflowBridge.step_execute(module_backed_store, adapter, %{
                 input: %{messages: [%{role: "user", content: "hello"}]},
                 context: %{system_prompt: "be concise"}
               })

      assert is_binary(result.session_id)
      assert is_binary(result.run_id)
      assert result.content == "ack: hello"
      assert result.persistence_failures == 0
    end
  end

  describe "step_execute/3 multi-run mode" do
    test "executes inside existing session", %{store: store, adapter: adapter} do
      {:ok, session_id} =
        WorkflowBridge.setup_workflow_session(store, adapter, %{agent_id: "workflow-test"})

      assert {:ok, %StepResult{} = result} =
               WorkflowBridge.step_execute(store, adapter, %{
                 session_id: session_id,
                 input: %{messages: [%{role: "user", content: "step one"}]}
               })

      assert result.session_id == session_id
      assert is_binary(result.run_id)
      assert result.content == "ack: step one"
    end

    test "supports continuation :auto", %{store: store, adapter: adapter} do
      {:ok, session_id} =
        WorkflowBridge.setup_workflow_session(store, adapter, %{agent_id: "workflow-test"})

      {:ok, _first} =
        WorkflowBridge.step_execute(store, adapter, %{
          session_id: session_id,
          input: %{messages: [%{role: "user", content: "remember this"}]}
        })

      {:ok, _second} =
        WorkflowBridge.step_execute(store, adapter, %{
          session_id: session_id,
          input: %{messages: [%{role: "user", content: "what did I say?"}]},
          continuation: :auto,
          continuation_opts: [max_messages: 20]
        })

      opts = BridgeMockAdapter.get_last_execute_opts(adapter)
      assert opts[:continuation] == :auto

      execute_session = BridgeMockAdapter.get_last_execute_session(adapter)
      assert %Transcript{} = execute_session.context.transcript
    end
  end

  describe "workflow session lifecycle" do
    test "setup_workflow_session/3 creates and activates a session", %{
      store: store,
      adapter: adapter
    } do
      assert {:ok, session_id} =
               WorkflowBridge.setup_workflow_session(store, adapter, %{
                 agent_id: "workflow-agent",
                 context: %{system_prompt: "x"},
                 metadata: %{workflow: "wf-1"}
               })

      {:ok, session} = SessionManager.get_session(store, session_id)
      assert session.status == :active
      assert session.agent_id == "workflow-agent"
      assert session.context.system_prompt == "x"
      assert session.metadata.workflow == "wf-1"
    end

    test "complete_workflow_session/3 completes session by default", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session_id} =
        WorkflowBridge.setup_workflow_session(store, adapter, %{agent_id: "workflow-agent"})

      assert :ok = WorkflowBridge.complete_workflow_session(store, session_id)

      {:ok, session} = SessionManager.get_session(store, session_id)
      assert session.status == :completed
    end

    test "complete_workflow_session/3 fails session when status: :failed", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session_id} =
        WorkflowBridge.setup_workflow_session(store, adapter, %{agent_id: "workflow-agent"})

      error = Error.new(:provider_error, "boom")

      assert :ok =
               WorkflowBridge.complete_workflow_session(store, session_id,
                 status: :failed,
                 error: error
               )

      {:ok, session} = SessionManager.get_session(store, session_id)
      assert session.status == :failed
    end
  end

  describe "classify_error/1" do
    test "classifies provider timeout", _ctx do
      classification = WorkflowBridge.classify_error(Error.new(:provider_timeout, "timed out"))
      assert %ErrorClassification{} = classification
      assert classification.retryable == true
      assert classification.category == :provider
      assert classification.recommended_action == :retry
    end

    test "classifies provider rate limited", _ctx do
      classification =
        WorkflowBridge.classify_error(Error.new(:provider_rate_limited, "rate limit"))

      assert classification.retryable == true
      assert classification.recommended_action == :wait_and_retry
    end

    test "classifies provider unavailable", _ctx do
      classification = WorkflowBridge.classify_error(Error.new(:provider_unavailable, "down"))
      assert classification.retryable == true
      assert classification.recommended_action == :failover
    end

    test "classifies validation error", _ctx do
      classification = WorkflowBridge.classify_error(Error.new(:validation_error, "bad"))
      assert classification.retryable == false
      assert classification.category == :validation
      assert classification.recommended_action == :abort
    end

    test "classifies session not found", _ctx do
      classification = WorkflowBridge.classify_error(Error.new(:session_not_found, "missing"))
      assert classification.retryable == false
      assert classification.recommended_action == :abort
    end

    test "classifies storage connection failed", _ctx do
      classification =
        WorkflowBridge.classify_error(Error.new(:storage_connection_failed, "down"))

      assert classification.retryable == true
      assert classification.category == :storage
      assert classification.recommended_action == :retry
    end

    test "classifies policy violation", _ctx do
      classification = WorkflowBridge.classify_error(Error.new(:policy_violation, "blocked"))
      assert classification.retryable == false
      assert classification.recommended_action == :cancel
    end
  end

  describe "step_result/1 normalization" do
    test "normalizes run_once result shape", _ctx do
      raw = %{
        output: %{content: "ok", stop_reason: "end_turn", tool_calls: []},
        token_usage: %{input_tokens: 1, output_tokens: 2},
        events: [%{type: :run_completed}],
        session_id: "ses_1",
        run_id: "run_1"
      }

      result = WorkflowBridge.step_result(raw)

      assert %StepResult{} = result
      assert result.session_id == "ses_1"
      assert result.run_id == "run_1"
      assert result.content == "ok"
      assert result.has_tool_calls == false
      assert result.persistence_failures == 0
    end

    test "normalizes execute_run result shape with overrides", _ctx do
      raw = %{
        output: %{
          "content" => "tool step",
          "stop_reason" => "tool_use",
          "tool_calls" => [%{"id" => "tool_1", "name" => "search"}]
        },
        token_usage: %{"input_tokens" => 2, "output_tokens" => 4},
        events: [%{type: :tool_call_started}],
        persistence_failures: 2,
        workspace: %{backend: :git},
        policy: %{action: :warn}
      }

      result = WorkflowBridge.step_result(raw, session_id: "ses_2", run_id: "run_2")

      assert result.session_id == "ses_2"
      assert result.run_id == "run_2"
      assert result.content == "tool step"
      assert result.stop_reason == "tool_use"
      assert result.has_tool_calls == true
      assert length(result.tool_calls) == 1
      assert result.persistence_failures == 2
      assert result.workspace == %{backend: :git}
      assert result.policy == %{action: :warn}
    end
  end

  describe "multi-step workflow integration" do
    test "setup -> 3 steps -> complete tracks runs under one session", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session_id} =
        WorkflowBridge.setup_workflow_session(store, adapter, %{agent_id: "workflow-integration"})

      {:ok, r1} =
        WorkflowBridge.step_execute(store, adapter, %{
          session_id: session_id,
          input: %{messages: [%{role: "user", content: "step 1"}]}
        })

      {:ok, r2} =
        WorkflowBridge.step_execute(store, adapter, %{
          session_id: session_id,
          input: %{messages: [%{role: "user", content: "step 2"}]},
          continuation: :auto,
          continuation_opts: [max_messages: 20]
        })

      {:ok, r3} =
        WorkflowBridge.step_execute(store, adapter, %{
          session_id: session_id,
          input: %{messages: [%{role: "user", content: "step 3"}]},
          continuation: :auto,
          continuation_opts: [max_messages: 20]
        })

      assert :ok = WorkflowBridge.complete_workflow_session(store, session_id)

      {:ok, runs} = SessionManager.get_session_runs(store, session_id)
      run_ids = MapSet.new(Enum.map(runs, & &1.id))

      assert MapSet.member?(run_ids, r1.run_id)
      assert MapSet.member?(run_ids, r2.run_id)
      assert MapSet.member?(run_ids, r3.run_id)
      assert length(runs) == 3

      {:ok, session} = SessionManager.get_session(store, session_id)
      assert session.status == :completed

      {:ok, events} = SessionStore.get_events(store, session_id)
      assert Enum.any?(events, &(&1.type == :session_completed))
    end
  end
end

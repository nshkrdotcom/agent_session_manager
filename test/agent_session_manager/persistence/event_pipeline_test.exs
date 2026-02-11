defmodule AgentSessionManager.Persistence.EventPipelineTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Persistence.EventPipeline
  alias AgentSessionManager.Ports.SessionStore

  setup do
    {:ok, store} = InMemorySessionStore.start_link()
    cleanup_on_exit(fn -> safe_stop(store) end)
    %{store: store}
  end

  defp default_context(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "ses_pipeline_test",
        run_id: "run_pipeline_test",
        provider: "claude"
      },
      overrides
    )
  end

  # ============================================================================
  # process/3
  # ============================================================================

  describe "process/3" do
    test "builds, enriches, validates, and persists an event", %{store: store} do
      context = default_context()
      raw = %{type: :run_started, data: %{model: "claude-haiku"}}

      {:ok, event} = EventPipeline.process(store, raw, context)

      assert event.type == :run_started
      assert event.session_id == "ses_pipeline_test"
      assert event.run_id == "run_pipeline_test"
      assert event.provider == "claude"
      assert event.sequence_number == 1
      assert event.data == %{model: "claude-haiku"}
    end

    test "assigns sequential sequence numbers", %{store: store} do
      context = default_context()

      {:ok, e1} = EventPipeline.process(store, %{type: :run_started}, context)

      {:ok, e2} =
        EventPipeline.process(
          store,
          %{type: :message_received, data: %{content: "hi", role: "assistant"}},
          context
        )

      {:ok, e3} =
        EventPipeline.process(
          store,
          %{type: :run_completed, data: %{stop_reason: "end_turn"}},
          context
        )

      assert e1.sequence_number == 1
      assert e2.sequence_number == 2
      assert e3.sequence_number == 3
    end

    test "enriches with provider from context", %{store: store} do
      context = default_context(%{provider: "codex"})
      {:ok, event} = EventPipeline.process(store, %{type: :run_started}, context)
      assert event.provider == "codex"
    end

    test "enriches with correlation_id from context", %{store: store} do
      context = default_context(%{correlation_id: "corr_123"})
      {:ok, event} = EventPipeline.process(store, %{type: :run_started}, context)
      assert event.correlation_id == "corr_123"
    end

    test "preserves adapter-provided data", %{store: store} do
      context = default_context()

      raw = %{
        type: :tool_call_started,
        data: %{tool_name: "bash", tool_input: %{command: "ls"}},
        metadata: %{source: "claude_sdk"}
      }

      {:ok, event} = EventPipeline.process(store, raw, context)
      assert event.data.tool_name == "bash"
      assert event.data.tool_input == %{command: "ls"}
      assert event.metadata.source == "claude_sdk"
    end

    test "preserves adapter-provided timestamp", %{store: store} do
      context = default_context()
      ts = ~U[2025-06-15 12:00:00Z]
      raw = %{type: :run_started, timestamp: ts}

      {:ok, event} = EventPipeline.process(store, raw, context)
      assert event.timestamp == ts
    end

    test "attaches shape warnings to metadata without rejecting", %{store: store} do
      context = default_context()
      # message_received requires content and role
      raw = %{type: :message_received, data: %{}}

      {:ok, event} = EventPipeline.process(store, raw, context)
      assert event.sequence_number != nil
      assert is_list(event.metadata._validation_warnings)
      assert length(event.metadata._validation_warnings) == 2
    end

    test "rejects structurally invalid events", %{store: store} do
      context = default_context()
      # Invalid type will be normalized to :error_occurred, so we test a nil session_id
      raw = %{type: :run_started}
      bad_context = %{context | session_id: ""}

      {:error, error} = EventPipeline.process(store, raw, bad_context)
      assert error.code == :validation_error
    end

    test "normalizes unknown type to :error_occurred", %{store: store} do
      context = default_context()
      raw = %{type: :completely_unknown_type}

      {:ok, event} = EventPipeline.process(store, raw, context)
      assert event.type == :error_occurred
    end

    test "normalizes string event types via EventNormalizer mappings", %{store: store} do
      context = default_context()

      {:ok, e1} = EventPipeline.process(store, %{type: "run_started"}, context)

      {:ok, e2} =
        EventPipeline.process(store, %{type: "message_streamed", data: %{content: "hi"}}, context)

      {:ok, e3} =
        EventPipeline.process(
          store,
          %{type: "run_completed", data: %{stop_reason: "done"}},
          context
        )

      assert e1.type == :run_started
      assert e2.type == :message_streamed
      assert e3.type == :run_completed
    end

    test "stores provider on event struct only", %{store: store} do
      context = default_context(%{provider: "codex"})
      {:ok, event} = EventPipeline.process(store, %{type: :run_started}, context)

      assert event.provider == "codex"
      refute Map.has_key?(event.metadata, :provider)
    end

    test "events are retrievable from store after processing", %{store: store} do
      context = default_context()
      {:ok, _} = EventPipeline.process(store, %{type: :session_created}, context)
      {:ok, _} = EventPipeline.process(store, %{type: :run_started}, context)

      {:ok, events} = SessionStore.get_events(store, "ses_pipeline_test")
      assert length(events) == 2
      assert Enum.map(events, & &1.type) == [:session_created, :run_started]
    end
  end

  describe "process/3 with redaction" do
    test "redacted events are persisted without secrets", %{store: store} do
      AgentSessionManager.Config.put(:redaction_enabled, true)
      on_exit(fn -> AgentSessionManager.Config.delete(:redaction_enabled) end)

      context = default_context()

      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: "export API_KEY=sk-ant-api03-secretvaluehere1234567890",
          tool_input: %{command: "env"}
        }
      }

      {:ok, event} = EventPipeline.process(store, raw, context)
      refute event.data.tool_output =~ "sk-ant-api03"

      {:ok, events} = SessionStore.get_events(store, "ses_pipeline_test")
      persisted = List.last(events)
      refute persisted.data.tool_output =~ "sk-ant-api03"
    end

    test "disabled redaction preserves original data", %{store: store} do
      context = default_context()

      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: "password=secret123"
        }
      }

      {:ok, event} = EventPipeline.process(store, raw, context)
      assert event.data.tool_output == "password=secret123"
    end
  end

  # ============================================================================
  # process_batch/3
  # ============================================================================

  describe "process_batch/3" do
    test "processes multiple events in order", %{store: store} do
      context = default_context()

      raw_events = [
        %{type: :run_started},
        %{type: :message_received, data: %{content: "Hello", role: "assistant"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, events} = EventPipeline.process_batch(store, raw_events, context)
      assert length(events) == 3
      assert Enum.map(events, & &1.sequence_number) == [1, 2, 3]
    end

    test "returns empty list for empty batch", %{store: store} do
      context = default_context()
      {:ok, []} = EventPipeline.process_batch(store, [], context)
    end

    test "halts on first structural failure", %{store: store} do
      bad_context = %{default_context() | session_id: ""}

      raw_events = [
        %{type: :run_started},
        %{type: :run_completed, data: %{stop_reason: "done"}}
      ]

      {:error, _} = EventPipeline.process_batch(store, raw_events, bad_context)
    end

    test "rejects entire batch and persists nothing when any raw event is invalid", %{
      store: store
    } do
      context = default_context()

      raw_events = [
        %{type: :run_started},
        :not_a_map,
        %{type: :run_completed, data: %{stop_reason: "done"}}
      ]

      assert {:error, _} = EventPipeline.process_batch(store, raw_events, context)
      assert {:ok, []} = SessionStore.get_events(store, context.session_id)
    end
  end

  describe "process_batch/3 with redaction" do
    test "batch processing redacts all events", %{store: store} do
      AgentSessionManager.Config.put(:redaction_enabled, true)
      on_exit(fn -> AgentSessionManager.Config.delete(:redaction_enabled) end)

      context = default_context()

      raw_events = [
        %{
          type: :tool_call_completed,
          data: %{
            tool_name: "bash",
            tool_output: "password=secret123"
          }
        },
        %{
          type: :message_received,
          data: %{
            content: "Your key is ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZaBcDeFgHiJkL",
            role: "assistant"
          }
        }
      ]

      {:ok, events} = EventPipeline.process_batch(store, raw_events, context)
      refute Enum.any?(events, fn event -> inspect(event.data) =~ "secret123" end)
      refute Enum.any?(events, fn event -> inspect(event.data) =~ "ghp_" end)
    end
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  describe "telemetry" do
    test "emits event_persisted telemetry", %{store: store} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:agent_session_manager, :persistence, :event_persisted]
        ])

      context = default_context()
      {:ok, _} = EventPipeline.process(store, %{type: :run_started}, context)

      assert_received {[:agent_session_manager, :persistence, :event_persisted], ^ref,
                       %{sequence_number: 1}, %{provider: "claude", type: :run_started}}
    end

    test "emits event_validation_warning telemetry on shape mismatch", %{store: store} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:agent_session_manager, :persistence, :event_validation_warning]
        ])

      context = default_context()
      {:ok, _} = EventPipeline.process(store, %{type: :message_received, data: %{}}, context)

      assert_received {[:agent_session_manager, :persistence, :event_validation_warning], ^ref,
                       %{warning_count: 2}, %{type: :message_received}}
    end

    test "emits event_rejected telemetry on structural failure", %{store: store} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:agent_session_manager, :persistence, :event_rejected]
        ])

      bad_context = %{default_context() | session_id: ""}
      {:error, _} = EventPipeline.process(store, %{type: :run_started}, bad_context)

      assert_received {[:agent_session_manager, :persistence, :event_rejected], ^ref,
                       %{system_time: _}, %{session_id: ""}}
    end
  end

  describe "telemetry with redaction" do
    test "emits event_redacted telemetry when secrets are found", %{store: store} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:agent_session_manager, :persistence, :event_redacted]
        ])

      AgentSessionManager.Config.put(:redaction_enabled, true)
      on_exit(fn -> AgentSessionManager.Config.delete(:redaction_enabled) end)

      context = default_context()

      raw = %{
        type: :tool_call_completed,
        data: %{
          tool_name: "bash",
          tool_output: "password=secret123"
        }
      }

      {:ok, _event} = EventPipeline.process(store, raw, context)

      assert_received {[:agent_session_manager, :persistence, :event_redacted], ^ref,
                       %{redaction_count: count}, %{type: :tool_call_completed}}

      assert count > 0
    end

    test "does not emit event_redacted telemetry when no secrets found", %{store: store} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:agent_session_manager, :persistence, :event_redacted]
        ])

      AgentSessionManager.Config.put(:redaction_enabled, true)
      on_exit(fn -> AgentSessionManager.Config.delete(:redaction_enabled) end)

      context = default_context()
      raw = %{type: :run_started, data: %{model: "claude-haiku"}}
      {:ok, _event} = EventPipeline.process(store, raw, context)

      refute_received {[:agent_session_manager, :persistence, :event_redacted], ^ref, _, _}
    end
  end
end

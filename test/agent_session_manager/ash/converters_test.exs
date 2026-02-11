if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.ConvertersTest do
    use ExUnit.Case, async: true
    @moduletag :ash

    alias AgentSessionManager.Ash.Converters
    alias AgentSessionManager.Core.{Event, Run, Session}
    import AgentSessionManager.Test.Fixtures

    test "record_to_session converts status and map keys" do
      now = DateTime.utc_now()

      record = %{
        id: "ses_1",
        agent_id: "agent-1",
        status: "active",
        parent_session_id: nil,
        metadata: %{"foo" => "bar"},
        context: %{"depth" => 2},
        tags: ["a"],
        created_at: now,
        updated_at: now,
        deleted_at: nil
      }

      session = Converters.record_to_session(record)

      assert %Session{} = session
      assert session.status == :active
      assert session.metadata == %{foo: "bar"}
      assert session.context == %{depth: 2}
      assert session.tags == ["a"]
    end

    test "session_to_attrs converts status and stringifies maps" do
      session =
        build_session(
          id: "ses_1",
          status: :paused,
          metadata: %{foo: "bar"},
          context: %{nested: %{x: 1}}
        )

      attrs = Converters.session_to_attrs(session)

      assert attrs.status == "paused"
      assert attrs.metadata == %{"foo" => "bar"}
      assert attrs.context == %{"nested" => %{"x" => 1}}
    end

    test "record_to_run and run_to_attrs convert status/map fields" do
      now = DateTime.utc_now()

      record = %{
        id: "run_1",
        session_id: "ses_1",
        status: "running",
        input: %{"prompt" => "hello"},
        output: nil,
        error: nil,
        metadata: %{"attempt" => 1},
        turn_count: 2,
        token_usage: %{"total_tokens" => 10},
        started_at: now,
        ended_at: nil,
        provider: "claude",
        provider_metadata: %{"model" => "sonnet"}
      }

      run = Converters.record_to_run(record)
      assert %Run{} = run
      assert run.status == :running
      assert run.input == %{prompt: "hello"}
      assert run.provider_metadata == %{model: "sonnet"}

      attrs = Converters.run_to_attrs(run)
      assert attrs.status == "running"
      assert attrs.input == %{"prompt" => "hello"}
      assert attrs.provider_metadata == %{"model" => "sonnet"}
    end

    test "record_to_event and event_to_attrs convert type/map fields" do
      now = DateTime.utc_now()

      record = %{
        id: "evt_1",
        type: "message_received",
        timestamp: now,
        session_id: "ses_1",
        run_id: "run_1",
        sequence_number: 7,
        data: %{"content" => "hi"},
        metadata: %{"m" => 1},
        schema_version: 1,
        provider: "claude",
        correlation_id: "c1"
      }

      event = Converters.record_to_event(record)
      assert %Event{} = event
      assert event.type == :message_received
      assert event.data == %{content: "hi"}

      attrs = Converters.event_to_attrs(event)
      assert attrs.type == "message_received"
      assert attrs.data == %{"content" => "hi"}
      assert attrs.sequence_number == 7
    end

    test "nil metadata and tags defaults" do
      now = DateTime.utc_now()

      record = %{
        id: "ses_1",
        agent_id: "agent-1",
        status: "pending",
        parent_session_id: nil,
        metadata: nil,
        context: nil,
        tags: nil,
        created_at: now,
        updated_at: now,
        deleted_at: nil
      }

      session = Converters.record_to_session(record)
      assert session.metadata == %{}
      assert session.context == %{}
      assert session.tags == []
    end

    test "session round trip preserves data" do
      session =
        build_session(
          id: "ses_rt",
          status: :completed,
          metadata: %{foo: "bar"},
          context: %{n: 1},
          tags: ["x"]
        )

      round_tripped = session |> Converters.session_to_attrs() |> Converters.record_to_session()

      assert round_tripped.id == session.id
      assert round_tripped.status == session.status
      assert round_tripped.metadata == session.metadata
      assert round_tripped.context == session.context
      assert round_tripped.tags == session.tags
    end
  end
end

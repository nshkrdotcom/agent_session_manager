if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Changes.AssignSequenceTest do
    use ExUnit.Case, async: false
    @moduletag :ash

    alias AgentSessionManager.Ash.Changes.AssignSequence
    alias AgentSessionManager.Ash.Resources
    alias AgentSessionManager.Ash.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    setup do
      :ok = Sandbox.checkout(TestRepo)
      :ok
    end

    test "next_sequence increments atomically" do
      repo = TestRepo
      session_id = "seq_test_1"

      assert 1 == AssignSequence.next_sequence(repo, session_id)
      assert 2 == AssignSequence.next_sequence(repo, session_id)
      assert 3 == AssignSequence.next_sequence(repo, session_id)
    end

    test "reserve_batch returns first sequence in contiguous range" do
      repo = TestRepo
      session_id = "seq_test_2"

      assert 1 == AssignSequence.reserve_batch(repo, session_id, 3)
      assert 4 == AssignSequence.reserve_batch(repo, session_id, 2)
    end

    test "concurrent next_sequence calls produce unique sequence numbers" do
      repo = TestRepo
      session_id = "seq_test_concurrent"
      owner = self()

      seqs =
        1..20
        |> Task.async_stream(
          fn _ ->
            Sandbox.allow(TestRepo, owner, self())
            AssignSequence.next_sequence(repo, session_id)
          end,
          ordered: false,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, seq} -> seq end)

      assert length(seqs) == 20
      assert Enum.uniq(seqs) |> length() == 20
      assert Enum.min(seqs) == 1
      assert Enum.max(seqs) == 20
    end

    test "append_with_sequence action assigns sequence_number" do
      now = DateTime.utc_now()
      sid = "seq_test_session"

      Ash.create!(
        Resources.Session,
        %{id: sid, agent_id: "a", status: "active", created_at: now, updated_at: now},
        action: :upsert,
        domain: AgentSessionManager.Ash.TestDomain
      )

      event =
        Ash.create!(
          Resources.Event,
          %{
            id: "evt_seq_1",
            type: "session_created",
            session_id: sid,
            timestamp: now,
            data: %{},
            metadata: %{}
          },
          action: :append_with_sequence,
          domain: AgentSessionManager.Ash.TestDomain
        )

      assert event.sequence_number == 1
    end
  end
end

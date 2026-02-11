if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Changes.AssignSequence do
    @moduledoc false

    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        session_id = Ash.Changeset.get_attribute(changeset, :session_id)
        repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

        seq = next_sequence(repo, session_id)
        Ash.Changeset.force_change_attribute(changeset, :sequence_number, seq)
      end)
    end

    @doc false
    def next_sequence(repo, session_id) do
      sql = """
      INSERT INTO asm_session_sequences (session_id, last_sequence)
      VALUES ($1, 1)
      ON CONFLICT (session_id)
      DO UPDATE SET last_sequence = asm_session_sequences.last_sequence + 1
      RETURNING last_sequence
      """

      %{rows: [[seq]]} = repo.query!(sql, [session_id])
      seq
    end

    @doc false
    def reserve_batch(repo, session_id, count) when is_integer(count) and count > 0 do
      sql = """
      INSERT INTO asm_session_sequences (session_id, last_sequence)
      VALUES ($1, $2)
      ON CONFLICT (session_id)
      DO UPDATE SET last_sequence = asm_session_sequences.last_sequence + $2
      RETURNING last_sequence
      """

      %{rows: [[last_seq]]} = repo.query!(sql, [session_id, count])
      last_seq - count + 1
    end
  end
else
  defmodule AgentSessionManager.Ash.Changes.AssignSequence do
    @moduledoc false
  end
end

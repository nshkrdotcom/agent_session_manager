if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Resources.SessionSequence do
    @moduledoc false

    use Ash.Resource,
      domain: AgentSessionManager.Ash.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("asm_session_sequences")
      repo(Application.compile_env(:agent_session_manager, :ash_repo))
    end

    attributes do
      attribute :session_id, :string do
        primary_key?(true)
        allow_nil?(false)
        writable?(true)
      end

      attribute(:last_sequence, :integer, default: 0)
      attribute(:updated_at, :utc_datetime_usec)
    end

    relationships do
      belongs_to :session, AgentSessionManager.Ash.Resources.Session do
        source_attribute(:session_id)
        destination_attribute(:id)
        define_attribute?(false)
      end
    end

    identities do
      identity(:session_id, [:session_id])
    end

    actions do
      defaults([:read])

      create :upsert do
        upsert?(true)
        upsert_identity(:session_id)
        upsert_fields({:replace_all_except, [:session_id]})
        accept([:session_id, :last_sequence, :updated_at])
      end
    end
  end
else
  defmodule AgentSessionManager.Ash.Resources.SessionSequence do
    @moduledoc false
  end
end

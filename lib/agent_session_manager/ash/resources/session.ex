if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Resources.Session do
    @moduledoc false

    use Ash.Resource,
      domain: AgentSessionManager.Ash.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("asm_sessions")
      repo(Application.compile_env(:agent_session_manager, :ash_repo))
    end

    attributes do
      attribute :id, :string do
        primary_key?(true)
        allow_nil?(false)
        writable?(true)
      end

      attribute :agent_id, :string do
        allow_nil?(false)
      end

      attribute :status, :string do
        allow_nil?(false)
      end

      attribute(:parent_session_id, :string)
      attribute(:metadata, :map, default: %{})
      attribute(:context, :map, default: %{})
      attribute(:tags, {:array, :string}, default: [])
      attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
      attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
      attribute(:deleted_at, :utc_datetime_usec)
    end

    relationships do
      has_many :runs, AgentSessionManager.Ash.Resources.Run do
        destination_attribute(:session_id)
      end

      has_many :events, AgentSessionManager.Ash.Resources.Event do
        destination_attribute(:session_id)
      end

      has_many :artifacts, AgentSessionManager.Ash.Resources.Artifact do
        destination_attribute(:session_id)
      end

      has_one :sequence, AgentSessionManager.Ash.Resources.SessionSequence do
        destination_attribute(:session_id)
      end
    end

    identities do
      identity(:id, [:id])
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([
          :id,
          :agent_id,
          :status,
          :parent_session_id,
          :metadata,
          :context,
          :tags,
          :created_at,
          :updated_at,
          :deleted_at
        ])
      end

      create :upsert do
        upsert?(true)
        upsert_identity(:id)
        upsert_fields({:replace_all_except, [:id]})

        accept([
          :id,
          :agent_id,
          :status,
          :parent_session_id,
          :metadata,
          :context,
          :tags,
          :created_at,
          :updated_at,
          :deleted_at
        ])
      end

      update :update do
        accept([:status, :metadata, :context, :tags, :updated_at, :deleted_at])
      end

      update :soft_delete do
        accept([])
        change(set_attribute(:deleted_at, &DateTime.utc_now/0))
      end
    end
  end
else
  defmodule AgentSessionManager.Ash.Resources.Session do
    @moduledoc false
  end
end

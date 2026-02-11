if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Resources.Artifact do
    @moduledoc false

    use Ash.Resource,
      domain: AgentSessionManager.Ash.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("asm_artifacts")
      repo(Application.compile_env(:agent_session_manager, :ash_repo))
    end

    attributes do
      attribute :id, :string do
        primary_key?(true)
        allow_nil?(false)
        writable?(true)
      end

      attribute(:session_id, :string)
      attribute(:run_id, :string)
      attribute(:key, :string, allow_nil?: false)
      attribute(:content_type, :string)
      attribute(:byte_size, :integer, allow_nil?: false)
      attribute(:checksum_sha256, :string, allow_nil?: false)
      attribute(:storage_backend, :string, allow_nil?: false)
      attribute(:storage_ref, :string, allow_nil?: false)
      attribute(:metadata, :map, default: %{})
      attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
      attribute(:deleted_at, :utc_datetime_usec)
    end

    relationships do
      belongs_to :session, AgentSessionManager.Ash.Resources.Session do
        source_attribute(:session_id)
        destination_attribute(:id)
        define_attribute?(false)
      end

      belongs_to :run, AgentSessionManager.Ash.Resources.Run do
        source_attribute(:run_id)
        destination_attribute(:id)
        define_attribute?(false)
      end
    end

    identities do
      identity(:id, [:id])
      identity(:key, [:key])
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([
          :id,
          :session_id,
          :run_id,
          :key,
          :content_type,
          :byte_size,
          :checksum_sha256,
          :storage_backend,
          :storage_ref,
          :metadata,
          :created_at,
          :deleted_at
        ])
      end
    end
  end
else
  defmodule AgentSessionManager.Ash.Resources.Artifact do
    @moduledoc false
  end
end

if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Resources.Event do
    @moduledoc false

    use Ash.Resource,
      domain: AgentSessionManager.Ash.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("asm_events")
      repo(Application.compile_env(:agent_session_manager, :ash_repo))
    end

    attributes do
      attribute :id, :string do
        primary_key?(true)
        allow_nil?(false)
        writable?(true)
      end

      attribute(:type, :string, allow_nil?: false)
      attribute(:timestamp, :utc_datetime_usec, allow_nil?: false)
      attribute(:session_id, :string, allow_nil?: false)
      attribute(:run_id, :string)
      attribute(:sequence_number, :integer, allow_nil?: false)
      attribute(:data, :map, default: %{})
      attribute(:metadata, :map, default: %{})
      attribute(:schema_version, :integer, default: 1)
      attribute(:provider, :string)
      attribute(:correlation_id, :string)
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
      identity(:session_sequence, [:session_id, :sequence_number])
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        accept([
          :id,
          :type,
          :timestamp,
          :session_id,
          :run_id,
          :sequence_number,
          :data,
          :metadata,
          :schema_version,
          :provider,
          :correlation_id
        ])
      end

      create :append_with_sequence do
        accept([
          :id,
          :type,
          :timestamp,
          :session_id,
          :run_id,
          :data,
          :metadata,
          :schema_version,
          :provider,
          :correlation_id
        ])

        change(AgentSessionManager.Ash.Changes.AssignSequence)
      end
    end
  end
else
  defmodule AgentSessionManager.Ash.Resources.Event do
    @moduledoc false
  end
end

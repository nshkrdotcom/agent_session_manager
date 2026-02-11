if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Resources.Run do
    @moduledoc false

    use Ash.Resource,
      domain: AgentSessionManager.Ash.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table("asm_runs")
      repo(Application.compile_env(:agent_session_manager, :ash_repo))
    end

    attributes do
      attribute :id, :string do
        primary_key?(true)
        allow_nil?(false)
        writable?(true)
      end

      attribute(:session_id, :string, allow_nil?: false)
      attribute(:status, :string, allow_nil?: false)
      attribute(:input, :map)
      attribute(:output, :map)
      attribute(:error, :map)
      attribute(:metadata, :map, default: %{})
      attribute(:turn_count, :integer, default: 0)
      attribute(:token_usage, :map, default: %{})
      attribute(:started_at, :utc_datetime_usec, allow_nil?: false)
      attribute(:ended_at, :utc_datetime_usec)
      attribute(:provider, :string)
      attribute(:provider_metadata, :map, default: %{})
    end

    relationships do
      belongs_to :session, AgentSessionManager.Ash.Resources.Session do
        source_attribute(:session_id)
        destination_attribute(:id)
        define_attribute?(false)
      end
    end

    identities do
      identity(:id, [:id])
    end

    actions do
      defaults([:read, :destroy])

      create :upsert do
        upsert?(true)
        upsert_identity(:id)
        upsert_fields({:replace_all_except, [:id]})

        accept([
          :id,
          :session_id,
          :status,
          :input,
          :output,
          :error,
          :metadata,
          :turn_count,
          :token_usage,
          :started_at,
          :ended_at,
          :provider,
          :provider_metadata
        ])
      end
    end
  end
else
  defmodule AgentSessionManager.Ash.Resources.Run do
    @moduledoc false
  end
end

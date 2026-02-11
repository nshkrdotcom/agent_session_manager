if Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Changeset) do
  defmodule AgentSessionManager.Adapters.EctoSessionStore.Schemas do
    @moduledoc """
    Ecto schemas for the EctoSessionStore adapter.

    These schemas define the database tables used to persist sessions,
    runs, events, and sequence counters. They work with any Ecto-compatible
    database (PostgreSQL, SQLite, etc).

    ## Tables

    - `asm_sessions` - Agent sessions
    - `asm_runs` - Execution runs within sessions
    - `asm_events` - Lifecycle events with sequence numbers
    - `asm_session_sequences` - Per-session atomic sequence counters
    """

    defmodule SessionSchema do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      schema "asm_sessions" do
        field(:agent_id, :string)
        field(:status, :string)
        field(:parent_session_id, :string)
        field(:metadata, :map, default: %{})
        field(:context, :map, default: %{})
        field(:tags, {:array, :string}, default: [])
        field(:created_at, :utc_datetime_usec)
        field(:updated_at, :utc_datetime_usec)
        field(:deleted_at, :utc_datetime_usec)
      end

      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [
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
        |> validate_required([:id, :agent_id, :status, :created_at, :updated_at])
      end
    end

    defmodule RunSchema do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      schema "asm_runs" do
        field(:session_id, :string)
        field(:status, :string)
        field(:input, :map)
        field(:output, :map)
        field(:error, :map)
        field(:metadata, :map, default: %{})
        field(:turn_count, :integer, default: 0)
        field(:token_usage, :map, default: %{})
        field(:started_at, :utc_datetime_usec)
        field(:ended_at, :utc_datetime_usec)
        field(:provider, :string)
        field(:cost_usd, :float)
        field(:provider_metadata, :map, default: %{})
      end

      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [
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
          :cost_usd,
          :provider_metadata
        ])
        |> validate_required([:id, :session_id, :status, :started_at])
      end
    end

    defmodule EventSchema do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      schema "asm_events" do
        field(:type, :string)
        field(:timestamp, :utc_datetime_usec)
        field(:session_id, :string)
        field(:run_id, :string)
        field(:sequence_number, :integer)
        field(:data, :map, default: %{})
        field(:metadata, :map, default: %{})
        field(:schema_version, :integer, default: 1)
        field(:provider, :string)
        field(:correlation_id, :string)
      end

      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [
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
        |> validate_required([:id, :type, :timestamp, :session_id])
      end
    end

    defmodule SessionSequenceSchema do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:session_id, :string, autogenerate: false}
      schema "asm_session_sequences" do
        field(:last_sequence, :integer, default: 0)
        field(:updated_at, :utc_datetime_usec)
      end

      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:session_id, :last_sequence, :updated_at])
        |> validate_required([:session_id, :last_sequence])
      end
    end

    defmodule ArtifactSchema do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      schema "asm_artifacts" do
        field(:session_id, :string)
        field(:run_id, :string)
        field(:key, :string)
        field(:content_type, :string)
        field(:byte_size, :integer)
        field(:checksum_sha256, :string)
        field(:storage_backend, :string)
        field(:storage_ref, :string)
        field(:metadata, :map, default: %{})
        field(:created_at, :utc_datetime_usec)
        field(:deleted_at, :utc_datetime_usec)
      end

      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [
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
        |> validate_required([
          :id,
          :key,
          :byte_size,
          :checksum_sha256,
          :storage_backend,
          :storage_ref,
          :created_at
        ])
      end
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore.Schemas do
    @moduledoc """
    Fallback schema definitions used when optional Ecto dependencies are not installed.
    """

    alias AgentSessionManager.OptionalDependency

    defmodule SessionSchema do
      @moduledoc false
      defstruct [
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
      ]

      def changeset(_schema, _attrs), do: raise_missing_dependency_error()

      defp raise_missing_dependency_error,
        do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :changeset))
    end

    defmodule RunSchema do
      @moduledoc false
      defstruct [
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
        :cost_usd,
        :provider_metadata
      ]

      def changeset(_schema, _attrs), do: raise_missing_dependency_error()

      defp raise_missing_dependency_error,
        do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :changeset))
    end

    defmodule EventSchema do
      @moduledoc false
      defstruct [
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
      ]

      def changeset(_schema, _attrs), do: raise_missing_dependency_error()

      defp raise_missing_dependency_error,
        do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :changeset))
    end

    defmodule SessionSequenceSchema do
      @moduledoc false
      defstruct [
        :session_id,
        :last_sequence,
        :updated_at
      ]

      def changeset(_schema, _attrs), do: raise_missing_dependency_error()

      defp raise_missing_dependency_error,
        do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :changeset))
    end

    defmodule ArtifactSchema do
      @moduledoc false
      defstruct [
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
      ]

      def changeset(_schema, _attrs), do: raise_missing_dependency_error()

      defp raise_missing_dependency_error,
        do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :changeset))
    end
  end
end

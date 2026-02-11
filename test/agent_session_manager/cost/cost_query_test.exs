defmodule AgentSessionManager.Cost.CostQueryTest do
  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.EctoQueryAPI
  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV2
  alias AgentSessionManager.Adapters.EctoSessionStore.MigrationV4
  alias AgentSessionManager.Core.{Run, Session}
  alias AgentSessionManager.Ports.{QueryAPI, SessionStore}

  defmodule CostQueryRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_cost_query_test.db")

  @pricing_table %{
    "claude" => %{
      default: %{input: 0.01, output: 0.02},
      models: %{
        "model-a" => %{input: 0.1, output: 0.2}
      }
    }
  }

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, CostQueryRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = CostQueryRepo.start_link()
    Ecto.Migrator.up(CostQueryRepo, 1, Migration, log: false)
    Ecto.Migrator.up(CostQueryRepo, 2, MigrationV2, log: false)
    Ecto.Migrator.up(CostQueryRepo, 4, MigrationV4, log: false)

    on_exit(fn ->
      safe_stop(repo_pid)
      File.rm(@db_path)
      File.rm(@db_path <> "-wal")
      File.rm(@db_path <> "-shm")
    end)

    :ok
  end

  setup do
    QueryAPIRepoCleaner.clean_all(CostQueryRepo)
    {:ok, store} = EctoSessionStore.start_link(repo: CostQueryRepo)
    %{store: store, query: {EctoQueryAPI, CostQueryRepo}}
  end

  describe "QueryAPI.get_cost_summary/2" do
    test "aggregates stored and post-hoc calculated costs", %{store: store, query: query} do
      _session_a = seed_session(store, "ses_a", "agent-a")
      _session_b = seed_session(store, "ses_b", "agent-b")

      seed_run(store, "ses_a", "run_1",
        provider: "claude",
        model: "model-b",
        input_tokens: 100,
        output_tokens: 50,
        cost_usd: 12.5
      )

      seed_run(store, "ses_a", "run_2",
        provider: "claude",
        model: "model-a",
        input_tokens: 10,
        output_tokens: 5,
        cost_usd: nil
      )

      seed_run(store, "ses_b", "run_3",
        provider: "unknown",
        model: "unknown-model",
        input_tokens: 20,
        output_tokens: 10,
        cost_usd: nil
      )

      {:ok, summary} = QueryAPI.get_cost_summary(query, pricing_table: @pricing_table)

      assert summary.run_count == 3
      assert summary.unmapped_runs == 1
      assert_in_delta summary.total_cost_usd, 14.5, 0.000001

      assert summary.by_provider["claude"].run_count == 2
      assert_in_delta summary.by_provider["claude"].cost_usd, 14.5, 0.000001

      assert_in_delta summary.by_model["model-b"].cost_usd, 12.5, 0.000001
      assert summary.by_model["model-b"].input_tokens == 100
      assert summary.by_model["model-b"].output_tokens == 50

      assert_in_delta summary.by_model["model-a"].cost_usd, 2.0, 0.000001
      assert summary.by_model["model-a"].input_tokens == 10
      assert summary.by_model["model-a"].output_tokens == 5
    end

    test "supports provider, session_id, and agent_id filters", %{store: store, query: query} do
      _session_a = seed_session(store, "ses_a", "agent-a")
      _session_b = seed_session(store, "ses_b", "agent-b")

      seed_run(store, "ses_a", "run_1",
        provider: "claude",
        model: "model-a",
        input_tokens: 10,
        output_tokens: 5,
        cost_usd: nil
      )

      seed_run(store, "ses_b", "run_2",
        provider: "claude",
        model: "model-a",
        input_tokens: 30,
        output_tokens: 10,
        cost_usd: nil
      )

      {:ok, by_session} =
        QueryAPI.get_cost_summary(query,
          pricing_table: @pricing_table,
          provider: "claude",
          session_id: "ses_a"
        )

      assert by_session.run_count == 1
      assert by_session.unmapped_runs == 0
      assert_in_delta by_session.total_cost_usd, 2.0, 0.000001

      {:ok, by_agent} =
        QueryAPI.get_cost_summary(query,
          pricing_table: @pricing_table,
          provider: "claude",
          agent_id: "agent-b"
        )

      assert by_agent.run_count == 1
      assert by_agent.unmapped_runs == 0
      assert_in_delta by_agent.total_cost_usd, 5.0, 0.000001
    end
  end

  defmodule QueryAPIRepoCleaner do
    @moduledoc false

    alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
      ArtifactSchema,
      EventSchema,
      RunSchema,
      SessionSchema,
      SessionSequenceSchema
    }

    def clean_all(repo) do
      repo.delete_all(EventSchema)
      repo.delete_all(RunSchema)
      repo.delete_all(ArtifactSchema)
      repo.delete_all(SessionSequenceSchema)
      repo.delete_all(SessionSchema)
    end
  end

  defp seed_session(store, id, agent_id) do
    {:ok, session} = Session.new(%{id: id, agent_id: agent_id})
    :ok = SessionStore.save_session(store, %{session | status: :active})
    session
  end

  defp seed_run(store, session_id, run_id, opts) do
    {:ok, run} = Run.new(%{id: run_id, session_id: session_id})

    run = %{
      run
      | status: :completed,
        provider: Keyword.fetch!(opts, :provider),
        provider_metadata: %{model: Keyword.get(opts, :model)},
        token_usage: %{
          input_tokens: Keyword.get(opts, :input_tokens, 0),
          output_tokens: Keyword.get(opts, :output_tokens, 0),
          total_tokens: Keyword.get(opts, :input_tokens, 0) + Keyword.get(opts, :output_tokens, 0)
        },
        cost_usd: Keyword.get(opts, :cost_usd)
    }

    :ok = SessionStore.save_run(store, run)
    run
  end
end

import Config

# Suppress info-level logs from dependency startup (codex_sdk OTLP, etc.)
config :logger, level: :warning

if Code.ensure_loaded?(AshPostgres.DataLayer) do
  config :agent_session_manager, AgentSessionManager.Ash.TestRepo,
    database: "asm_ash_test",
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10

  config :agent_session_manager, :ash_repo, AgentSessionManager.Ash.TestRepo
end

# Configure ExUnit
ExUnit.start(exclude: [:skip, :load_test])

# Define Mox mocks
Mox.defmock(AgentSessionManager.MockS3Client,
  for: AgentSessionManager.Adapters.S3ArtifactStore.S3Client
)

# Ensure Supertester is available and configured
# The supertester library provides:
# - Robust test isolation with Supertester.ExUnitFoundation
# - Deterministic async testing via TestableGenServer
# - Process lifecycle assertions via Supertester.Assertions
# - Performance testing via Supertester.PerformanceHelpers
# - Chaos engineering via Supertester.ChaosHelpers

# Import test fixtures for easy access
# Usage in tests:
#   use AgentSessionManager.SupertesterCase, async: true
#
# Or for simple tests without full supertester infrastructure:
#   import AgentSessionManager.Test.Fixtures

if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  {:ok, _} = AgentSessionManager.Ash.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(AgentSessionManager.Ash.TestRepo, :manual)

  Ecto.Migrator.up(
    AgentSessionManager.Ash.TestRepo,
    1,
    AgentSessionManager.Adapters.EctoSessionStore.Migration,
    log: false
  )

  Ecto.Migrator.up(
    AgentSessionManager.Ash.TestRepo,
    2,
    AgentSessionManager.Adapters.EctoSessionStore.MigrationV2,
    log: false
  )

  Ecto.Migrator.up(
    AgentSessionManager.Ash.TestRepo,
    3,
    AgentSessionManager.Adapters.EctoSessionStore.MigrationV3,
    log: false
  )
end

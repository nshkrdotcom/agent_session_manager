# Configure ExUnit
ash_loaded? =
  Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer)

ash_db_available? =
  case :gen_tcp.connect(~c"127.0.0.1", 5432, [:binary, active: false], 100) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    _ ->
      false
  end

run_ash_tests? =
  ash_loaded? and ash_db_available? and System.get_env("RUN_ASH_TESTS") in ["1", "true", "TRUE"]

base_excludes = [:skip, :load_test]
excludes = if run_ash_tests?, do: base_excludes, else: [:ash | base_excludes]
ExUnit.start(exclude: excludes)

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

if run_ash_tests? do
  with {:ok, _} <- AgentSessionManager.Ash.TestRepo.start_link() do
    Ecto.Adapters.SQL.Sandbox.mode(AgentSessionManager.Ash.TestRepo, :manual)

    Ecto.Migrator.up(
      AgentSessionManager.Ash.TestRepo,
      1,
      AgentSessionManager.Adapters.EctoSessionStore.Migration,
      log: false
    )
  end
end

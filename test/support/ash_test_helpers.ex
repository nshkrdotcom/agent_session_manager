if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.TestRepo do
    use AshPostgres.Repo,
      otp_app: :agent_session_manager,
      warn_on_missing_ash_functions?: false

    def min_pg_version do
      %Version{major: 16, minor: 0, patch: 0}
    end
  end

  defmodule AgentSessionManager.Ash.TestDomain do
    use Ash.Domain

    resources do
      resource(AgentSessionManager.Ash.Resources.Session)
      resource(AgentSessionManager.Ash.Resources.Run)
      resource(AgentSessionManager.Ash.Resources.Event)
      resource(AgentSessionManager.Ash.Resources.SessionSequence)
      resource(AgentSessionManager.Ash.Resources.Artifact)
    end
  end
end

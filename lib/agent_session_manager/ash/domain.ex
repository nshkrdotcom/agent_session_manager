if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.Domain do
    @moduledoc """
    Ash domain for AgentSessionManager persistence resources.
    """

    use Ash.Domain

    resources do
      resource(AgentSessionManager.Ash.Resources.Session)
      resource(AgentSessionManager.Ash.Resources.Run)
      resource(AgentSessionManager.Ash.Resources.Event)
      resource(AgentSessionManager.Ash.Resources.SessionSequence)
      resource(AgentSessionManager.Ash.Resources.Artifact)
    end
  end
else
  defmodule AgentSessionManager.Ash.Domain do
    @moduledoc false
  end
end

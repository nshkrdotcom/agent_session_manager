defmodule AgentSessionManager.TestRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :agent_session_manager,
    adapter: Ecto.Adapters.SQLite3
end

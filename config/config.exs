import Config

config :agent_session_manager, ash_domains: [AgentSessionManager.Ash.Domain]

import_config "#{config_env()}.exs"

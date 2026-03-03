import Config

config :agent_session_manager,
  queue_limit: 1_000,
  overflow_policy: :fail_run,
  subscriber_queue_warn: 100,
  subscriber_queue_limit: 500,
  approval_timeout_ms: 120_000

import_config "#{config_env()}.exs"

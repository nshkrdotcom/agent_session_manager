import Config

# Suppress info-level logs from dependency startup (codex_sdk OTLP, etc.)
config :logger, level: :warning

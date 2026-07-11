import Config

# Snapshot only the env vars ASM actually reads (provider namespaces + a
# small static set) — a whole-System.get_env() copy would spread every
# unrelated secret in the parent environment into inspectable Application
# config (Application.get_all_env/1, :observer, crash dumps).
config :agent_session_manager, :env, ASM.EnvSnapshot.take(System.get_env())

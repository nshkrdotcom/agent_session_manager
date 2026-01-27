defmodule AgentSessionManager.Config do
  @moduledoc """
  Centralized configuration with process-local overrides.

  Configuration values are resolved in priority order:

  1. **Process-local override** — set via `put/2`, scoped to the calling process.
     Automatically cleaned up when the process exits.
  2. **Application environment** — set via `config :agent_session_manager, key: value`
     or `Application.put_env/3`.
  3. **Built-in default** — hardcoded fallback per key.

  This layering follows the same pattern as Elixir's `Logger` module for per-process
  log levels. It enables fully concurrent (`async: true`) testing because each test
  process can override configuration without affecting any other process.

  ## Supported Keys

  | Key                      | Type      | Default |
  |--------------------------|-----------|---------|
  | `:telemetry_enabled`     | `boolean` | `true`  |
  | `:audit_logging_enabled` | `boolean` | `true`  |

  ## Examples

      # Read (checks process-local first, then app env, then default)
      AgentSessionManager.Config.get(:telemetry_enabled)
      #=> true

      # Set process-local override
      AgentSessionManager.Config.put(:telemetry_enabled, false)
      AgentSessionManager.Config.get(:telemetry_enabled)
      #=> false

      # Clear process-local override (falls back to app env / default)
      AgentSessionManager.Config.delete(:telemetry_enabled)

  """

  @typedoc "Configuration keys supported by this module."
  @type key :: :telemetry_enabled | :audit_logging_enabled

  @valid_keys [:telemetry_enabled, :audit_logging_enabled]

  @doc """
  Returns the resolved value for `key`.

  Checks the process dictionary first, then Application environment,
  then falls back to the built-in default.
  """
  @spec get(key()) :: term()
  def get(key) when key in @valid_keys do
    case Process.get({__MODULE__, key}, :__config_not_set__) do
      :__config_not_set__ ->
        Application.get_env(:agent_session_manager, key, default(key))

      value ->
        value
    end
  end

  @doc """
  Sets a process-local override for `key`.

  This override is visible only to the calling process and is automatically
  cleaned up when the process exits. It takes priority over Application
  environment and built-in defaults.
  """
  @spec put(key(), term()) :: :ok
  def put(key, value) when key in @valid_keys do
    Process.put({__MODULE__, key}, value)
    :ok
  end

  @doc """
  Removes the process-local override for `key`.

  After deletion, `get/1` falls back to Application environment or the
  built-in default.
  """
  @spec delete(key()) :: :ok
  def delete(key) when key in @valid_keys do
    Process.delete({__MODULE__, key})
    :ok
  end

  @doc """
  Returns the built-in default for `key`.
  """
  @spec default(key()) :: term()
  def default(:telemetry_enabled), do: true
  def default(:audit_logging_enabled), do: true
end

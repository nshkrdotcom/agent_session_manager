defmodule AgentSessionManager.Runtime.SessionRegistry do
  @moduledoc """
  Thin wrapper around Elixir `Registry` for locating per-session runtimes.

  `SessionServer` processes can be named via `via_tuple/2`, enabling lookup
  by `session_id` without hardcoding process names.
  """

  @type registry :: atom() | pid()
  @type session_id :: String.t()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    keys = Keyword.get(opts, :keys, :unique)

    Registry.child_spec(keys: keys, name: name)
  end

  @spec via_tuple(registry(), session_id()) :: {:via, Registry, {registry(), session_id()}}
  def via_tuple(registry, session_id) when is_binary(session_id) do
    {:via, Registry, {registry, session_id}}
  end

  @spec lookup(registry(), session_id()) :: {:ok, pid()} | :error
  def lookup(registry, session_id) when is_binary(session_id) do
    case Registry.lookup(registry, session_id) do
      [{pid, _value} | _] -> {:ok, pid}
      [] -> :error
    end
  end
end

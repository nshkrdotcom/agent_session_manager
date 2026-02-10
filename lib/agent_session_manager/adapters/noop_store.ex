defmodule AgentSessionManager.Adapters.NoopStore do
  @moduledoc """
  `DurableStore` implementation that discards writes and returns empty reads.
  """

  @behaviour AgentSessionManager.Ports.DurableStore

  alias AgentSessionManager.Core.{Error, Event}

  @impl AgentSessionManager.Ports.DurableStore
  @spec flush(module(), map()) :: :ok
  def flush(_store, _execution_result), do: :ok

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_run(module(), String.t()) :: {:error, Error.t()}
  def load_run(_store, run_id) do
    {:error, Error.new(:not_found, "No run found in NoopStore: #{run_id}")}
  end

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_session(module(), String.t()) :: {:error, Error.t()}
  def load_session(_store, session_id) do
    {:error, Error.new(:not_found, "No session found in NoopStore: #{session_id}")}
  end

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_events(module(), String.t(), keyword()) :: {:ok, [Event.t()]}
  def load_events(_store, _session_id, _opts \\ []) do
    {:ok, []}
  end
end

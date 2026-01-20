defmodule AgentSessionManager do
  @moduledoc """
  A comprehensive Elixir library for managing AI agent sessions, state persistence,
  conversation context, and multi-agent orchestration workflows.

  ## Core Domain Types

  This library provides the following core domain types:

  - `AgentSessionManager.Core.Session` - Represents an AI agent session
  - `AgentSessionManager.Core.Run` - Represents a single execution run within a session
  - `AgentSessionManager.Core.Event` - Represents events in the session lifecycle
  - `AgentSessionManager.Core.Capability` - Represents agent capabilities
  - `AgentSessionManager.Core.Manifest` - Represents an agent manifest
  - `AgentSessionManager.Core.CapabilityResolver` - Negotiates capabilities between requirements and providers
  - `AgentSessionManager.Core.Registry` - Thread-safe registry for provider manifests
  - `AgentSessionManager.Core.Error` - Normalized error taxonomy

  ## Quick Start

      # Create a session
      alias AgentSessionManager.Core.Session

      {:ok, session} = Session.new(%{agent_id: "my-agent"})
      {:ok, active} = Session.update_status(session, :active)

      # Create a run
      alias AgentSessionManager.Core.Run

      {:ok, run} = Run.new(%{session_id: session.id})
      {:ok, completed} = Run.set_output(run, %{response: "Hello!"})

      # Create an event
      alias AgentSessionManager.Core.Event

      {:ok, event} = Event.new(%{
        type: :message_received,
        session_id: session.id,
        run_id: run.id,
        data: %{content: "Hello!"}
      })

      # Define a manifest
      alias AgentSessionManager.Core.Manifest

      {:ok, manifest} = Manifest.new(%{
        name: "my-agent",
        version: "1.0.0",
        capabilities: [
          %{name: "web_search", type: :tool}
        ]
      })

  ## Error Handling

  All operations return tagged tuples `{:ok, result}` or `{:error, error}`.
  Errors are normalized using `AgentSessionManager.Core.Error`:

      alias AgentSessionManager.Core.Error

      case Session.new(%{}) do
        {:ok, session} -> session
        {:error, %Error{code: :validation_error, message: msg}} ->
          IO.puts("Validation failed: \#{msg}")
      end

  Errors support machine-readable codes, provider-specific details, and
  are classified into categories (validation, provider, storage, etc.).

  """

  # Re-export core types for convenience
  defdelegate new_session(attrs), to: AgentSessionManager.Core.Session, as: :new
  defdelegate new_run(attrs), to: AgentSessionManager.Core.Run, as: :new
  defdelegate new_event(attrs), to: AgentSessionManager.Core.Event, as: :new
  defdelegate new_capability(attrs), to: AgentSessionManager.Core.Capability, as: :new
  defdelegate new_manifest(attrs), to: AgentSessionManager.Core.Manifest, as: :new

  # Registry and capability resolution
  defdelegate new_registry(), to: AgentSessionManager.Core.Registry, as: :new

  defdelegate new_capability_resolver(opts),
    to: AgentSessionManager.Core.CapabilityResolver,
    as: :new
end

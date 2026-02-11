defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/nshkrdotcom/agent_session_manager"

  def project do
    [
      app: :agent_session_manager,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "AgentSessionManager",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},

      # Agent SDKs
      {:codex_sdk, "~> 0.8.0", optional: true},
      {:claude_agent_sdk, "~> 0.12.0", optional: true},
      {:amp_sdk, "~> 0.2", optional: true},

      # Persistence adapters (optional — consumers pick what they need)
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.19", optional: true},
      {:ecto_sqlite3, "~> 0.17", optional: true},
      # Ash Framework (optional -- alternative to raw Ecto adapters)
      {:ash, "~> 3.0", optional: true},
      {:ash_postgres, "~> 2.0", optional: true},
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},
      {:hackney, "~> 1.20", optional: true},
      # PubSub integration (optional)
      {:phoenix_pubsub, "~> 2.1", optional: true},

      # Development and documentation
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},

      # Testing
      {:supertester, "~> 0.5.1", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp description do
    """
    A comprehensive Elixir library for managing AI agent sessions, state persistence,
    conversation context, and multi-agent orchestration workflows.
    """
  end

  defp docs do
    [
      main: "readme",
      name: "AgentSessionManager",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/agent_session_manager.svg",
      extras: [
        "README.md",
        "guides/getting_started.md",
        "guides/live_examples.md",
        "guides/architecture.md",
        "guides/configuration.md",
        "guides/model_configuration.md",
        "guides/sessions_and_runs.md",
        "guides/session_server_runtime.md",
        "guides/session_server_subscriptions.md",
        "guides/session_continuity.md",
        "guides/events_and_streaming.md",
        "guides/rendering.md",
        "guides/pubsub_integration.md",
        "guides/stream_session.md",
        "guides/cursor_streaming_and_migration.md",
        "guides/workspace_snapshots.md",
        "guides/provider_routing.md",
        "guides/policy_enforcement.md",
        "guides/advanced_patterns.md",
        "guides/workflow_bridge.md",
        "guides/provider_adapters.md",
        "guides/shell_runner.md",
        "guides/capabilities.md",
        "guides/concurrency.md",
        "guides/telemetry_and_observability.md",
        "guides/error_handling.md",
        "guides/testing.md",
        "guides/persistence_overview.md",
        "guides/migrating_to_v0.8.md",
        "guides/ecto_session_store.md",
        "guides/ash_session_store.md",
        "guides/sqlite_session_store.md",
        "guides/s3_artifact_store.md",
        "guides/composite_store.md",
        "guides/event_schema_versioning.md",
        "guides/custom_persistence_guide.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Introduction: [
          "README.md",
          "guides/getting_started.md",
          "guides/live_examples.md",
          "guides/architecture.md",
          "guides/configuration.md",
          "guides/model_configuration.md"
        ],
        "Core Concepts": [
          "guides/sessions_and_runs.md",
          "guides/session_server_runtime.md",
          "guides/session_server_subscriptions.md",
          "guides/session_continuity.md",
          "guides/events_and_streaming.md",
          "guides/rendering.md",
          "guides/pubsub_integration.md",
          "guides/stream_session.md",
          "guides/cursor_streaming_and_migration.md",
          "guides/workspace_snapshots.md",
          "guides/provider_routing.md",
          "guides/policy_enforcement.md",
          "guides/advanced_patterns.md",
          "guides/capabilities.md"
        ],
        Persistence: [
          "guides/persistence_overview.md",
          "guides/migrating_to_v0.8.md",
          "guides/ecto_session_store.md",
          "guides/ash_session_store.md",
          "guides/sqlite_session_store.md",
          "guides/s3_artifact_store.md",
          "guides/composite_store.md",
          "guides/event_schema_versioning.md",
          "guides/custom_persistence_guide.md"
        ],
        Integration: [
          "guides/provider_adapters.md",
          "guides/workflow_bridge.md",
          "guides/shell_runner.md",
          "guides/concurrency.md",
          "guides/telemetry_and_observability.md"
        ],
        Reference: [
          "guides/error_handling.md",
          "guides/testing.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Core Domain": [
          AgentSessionManager,
          AgentSessionManager.Core.Session,
          AgentSessionManager.Core.Run,
          AgentSessionManager.Core.Event,
          AgentSessionManager.Core.Transcript,
          AgentSessionManager.Core.NormalizedEvent,
          AgentSessionManager.Core.Capability,
          AgentSessionManager.Core.Manifest,
          AgentSessionManager.Core.Error
        ],
        "Event Pipeline": [
          AgentSessionManager.Core.EventNormalizer,
          AgentSessionManager.Core.EventStream,
          AgentSessionManager.Core.TranscriptBuilder
        ],
        "Capability System": [
          AgentSessionManager.Core.CapabilityResolver,
          AgentSessionManager.Core.CapabilityResolver.NegotiationResult,
          AgentSessionManager.Core.Registry
        ],
        Orchestration: [
          AgentSessionManager.SessionManager,
          AgentSessionManager.Routing.ProviderRouter
        ],
        "Workflow Integration": [
          AgentSessionManager.WorkflowBridge,
          AgentSessionManager.WorkflowBridge.StepResult,
          AgentSessionManager.WorkflowBridge.ErrorClassification
        ],
        "Routing and Policy": [
          AgentSessionManager.Routing.RoutingPolicy,
          AgentSessionManager.Routing.CapabilityMatcher,
          AgentSessionManager.Routing.CircuitBreaker,
          AgentSessionManager.Policy.Policy,
          AgentSessionManager.Policy.Evaluator,
          AgentSessionManager.Policy.Runtime,
          AgentSessionManager.Policy.AdapterCompiler,
          AgentSessionManager.Policy.Preflight
        ],
        "Ports (Interfaces)": [
          AgentSessionManager.Ports.ProviderAdapter,
          AgentSessionManager.Ports.SessionStore,
          AgentSessionManager.Ports.ArtifactStore
        ],
        "Adapters (Implementations)": [
          AgentSessionManager.Adapters.ClaudeAdapter,
          AgentSessionManager.Adapters.CodexAdapter,
          AgentSessionManager.Adapters.AmpAdapter,
          AgentSessionManager.Adapters.ShellAdapter,
          AgentSessionManager.Adapters.InMemorySessionStore,
          AgentSessionManager.Adapters.FileArtifactStore,
          AgentSessionManager.Adapters.EctoSessionStore,
          AgentSessionManager.Ash.Adapters.AshSessionStore,
          AgentSessionManager.Ash.Adapters.AshQueryAPI,
          AgentSessionManager.Ash.Adapters.AshMaintenance,
          AgentSessionManager.Adapters.S3ArtifactStore,
          AgentSessionManager.Adapters.CompositeSessionStore
        ],
        "Ash Integration": [
          AgentSessionManager.Ash.Domain,
          AgentSessionManager.Ash.Resources.Session,
          AgentSessionManager.Ash.Resources.Run,
          AgentSessionManager.Ash.Resources.Event,
          AgentSessionManager.Ash.Resources.SessionSequence,
          AgentSessionManager.Ash.Resources.Artifact,
          AgentSessionManager.Ash.Adapters.AshSessionStore,
          AgentSessionManager.Ash.Adapters.AshQueryAPI,
          AgentSessionManager.Ash.Adapters.AshMaintenance
        ],
        Concurrency: [
          AgentSessionManager.Concurrency.ConcurrencyLimiter,
          AgentSessionManager.Concurrency.ControlOperations
        ],
        Runtime: [
          AgentSessionManager.Runtime.RunQueue,
          AgentSessionManager.Runtime.SessionRegistry,
          AgentSessionManager.Runtime.SessionServer,
          AgentSessionManager.Runtime.SessionSupervisor
        ],
        Workspace: [
          AgentSessionManager.Workspace.Workspace,
          AgentSessionManager.Workspace.Exec,
          AgentSessionManager.Workspace.Snapshot,
          AgentSessionManager.Workspace.Diff,
          AgentSessionManager.Workspace.GitBackend,
          AgentSessionManager.Workspace.HashBackend
        ],
        Rendering: [
          AgentSessionManager.Rendering,
          AgentSessionManager.Rendering.Renderer,
          AgentSessionManager.Rendering.Sink,
          AgentSessionManager.Rendering.Renderers.CompactRenderer,
          AgentSessionManager.Rendering.Renderers.VerboseRenderer,
          AgentSessionManager.Rendering.Renderers.PassthroughRenderer,
          AgentSessionManager.Rendering.Sinks.TTYSink,
          AgentSessionManager.Rendering.Sinks.FileSink,
          AgentSessionManager.Rendering.Sinks.JSONLSink,
          AgentSessionManager.Rendering.Sinks.CallbackSink,
          AgentSessionManager.Rendering.Sinks.PubSubSink
        ],
        "Stream Session": [
          AgentSessionManager.StreamSession,
          AgentSessionManager.StreamSession.Supervisor
        ],
        "PubSub Integration": [
          AgentSessionManager.PubSub,
          AgentSessionManager.PubSub.Topic
        ],
        Configuration: [
          AgentSessionManager.Models,
          AgentSessionManager.Cost.CostCalculator
        ],
        Observability: [
          AgentSessionManager.Config,
          AgentSessionManager.Telemetry,
          AgentSessionManager.AuditLogger
        ]
      ]
    ]
  end

  defp package do
    [
      name: "agent_session_manager",
      description: description(),
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/agent_session_manager",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end
end

defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @version "0.7.0"
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
      {:codex_sdk, "~> 0.7"},
      {:claude_agent_sdk, "~> 0.11"},
      {:amp_sdk, "~> 0.2"},

      # Development and documentation
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},

      # Testing
      {:supertester, "~> 0.5.1", only: :test}
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
        "guides/sessions_and_runs.md",
        "guides/session_server_runtime.md",
        "guides/session_server_subscriptions.md",
        "guides/session_continuity.md",
        "guides/events_and_streaming.md",
        "guides/rendering.md",
        "guides/cursor_streaming_and_migration.md",
        "guides/workspace_snapshots.md",
        "guides/provider_routing.md",
        "guides/policy_enforcement.md",
        "guides/advanced_patterns.md",
        "guides/provider_adapters.md",
        "guides/capabilities.md",
        "guides/concurrency.md",
        "guides/telemetry_and_observability.md",
        "guides/error_handling.md",
        "guides/testing.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Introduction: [
          "README.md",
          "guides/getting_started.md",
          "guides/live_examples.md",
          "guides/architecture.md",
          "guides/configuration.md"
        ],
        "Core Concepts": [
          "guides/sessions_and_runs.md",
          "guides/session_server_runtime.md",
          "guides/session_server_subscriptions.md",
          "guides/session_continuity.md",
          "guides/events_and_streaming.md",
          "guides/rendering.md",
          "guides/cursor_streaming_and_migration.md",
          "guides/workspace_snapshots.md",
          "guides/provider_routing.md",
          "guides/policy_enforcement.md",
          "guides/advanced_patterns.md",
          "guides/capabilities.md"
        ],
        Integration: [
          "guides/provider_adapters.md",
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
          AgentSessionManager.Adapters.InMemorySessionStore,
          AgentSessionManager.Adapters.FileArtifactStore
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
          AgentSessionManager.Rendering.Sinks.CallbackSink
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

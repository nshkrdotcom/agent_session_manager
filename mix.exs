defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @version "0.2.1"
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
      {:codex_sdk, "~> 0.6.0"},
      {:claude_agent_sdk, "~> 0.10.0"},

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
        "guides/architecture.md",
        "guides/configuration.md",
        "guides/sessions_and_runs.md",
        "guides/events_and_streaming.md",
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
          "guides/architecture.md",
          "guides/configuration.md"
        ],
        "Core Concepts": [
          "guides/sessions_and_runs.md",
          "guides/events_and_streaming.md",
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
          AgentSessionManager.Core.NormalizedEvent,
          AgentSessionManager.Core.Capability,
          AgentSessionManager.Core.Manifest,
          AgentSessionManager.Core.Error
        ],
        "Event Pipeline": [
          AgentSessionManager.Core.EventNormalizer,
          AgentSessionManager.Core.EventStream
        ],
        "Capability System": [
          AgentSessionManager.Core.CapabilityResolver,
          AgentSessionManager.Core.CapabilityResolver.NegotiationResult,
          AgentSessionManager.Core.Registry
        ],
        Orchestration: [
          AgentSessionManager.SessionManager
        ],
        "Ports (Interfaces)": [
          AgentSessionManager.Ports.ProviderAdapter,
          AgentSessionManager.Ports.SessionStore
        ],
        "Adapters (Implementations)": [
          AgentSessionManager.Adapters.ClaudeAdapter,
          AgentSessionManager.Adapters.CodexAdapter,
          AgentSessionManager.Adapters.InMemorySessionStore
        ],
        Concurrency: [
          AgentSessionManager.Concurrency.ConcurrencyLimiter,
          AgentSessionManager.Concurrency.ControlOperations
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

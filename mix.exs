defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @app :agent_session_manager
  @version "0.9.2"
  @source_url "https://github.com/nshkrdotcom/agent_session_manager"
  @homepage_url "https://hex.pm/packages/agent_session_manager"
  @docs_url "https://hexdocs.pm/agent_session_manager"
  @cli_subprocess_core_version "~> 0.1.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      compilers: project_compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      name: "ASM",
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {ASM.Application, []},
      extra_applications: [:logger]
    ]
  end

  def cli do
    []
  end

  defp project_compilers do
    if boundary_checks_enabled?() do
      [:boundary | Mix.compilers()]
    else
      Mix.compilers()
    end
  end

  defp deps do
    [
      cli_subprocess_core_dep(),
      {:boundary, "~> 0.10.4", runtime: false},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:zoi, "~> 0.17"},
      {:telemetry, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:nimble_ownership, "~> 1.0", only: :test},
      {:stream_data, "~> 1.3", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:supertester, "~> 0.6.0", only: :test}
    ]
  end

  defp cli_subprocess_core_dep do
    case local_dep_path("../cli_subprocess_core") do
      nil -> {:cli_subprocess_core, @cli_subprocess_core_version}
      path -> {:cli_subprocess_core, path: path}
    end
  end

  defp local_dep_path(relative_path) do
    if local_workspace_deps?() do
      path = Path.expand(relative_path, __DIR__)
      if File.dir?(path), do: path
    end
  end

  defp local_workspace_deps? do
    not hex_packaging_task?() and not Enum.member?(Path.split(__DIR__), "deps")
  end

  defp hex_packaging_task? do
    Enum.any?(System.argv(), &(&1 in ["hex.build", "hex.publish"]))
  end

  defp boundary_checks_enabled? do
    Mix.env() in [:dev, :test] and is_nil(Mix.ProjectStack.peek())
  end

  defp description do
    "Lean OTP-correct multi-provider CLI session runtime (ASM)."
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts"
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo",
        "cmd env MIX_ENV=test mix test",
        "dialyzer"
      ]
    ]
  end

  defp package do
    [
      name: "agent_session_manager",
      description: description(),
      files: ~w(lib assets mix.exs README.md CHANGELOG.md LICENSE .formatter.exs guides),
      licenses: ["MIT"],
      maintainers: ["nshkrdotcom"],
      links: %{
        "GitHub" => @source_url,
        "Hex" => @homepage_url,
        "HexDocs" => @docs_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "overview",
      logo: "assets/agent_session_manager.svg",
      assets: %{"assets" => "assets"},
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @homepage_url,
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      nest_modules_by_prefix: [
        ASM,
        ASM.Content,
        ASM.Control,
        ASM.Extensions,
        ASM.Message,
        ASM.Options,
        ASM.Pipeline,
        ASM.Provider,
        ASM.ProviderBackend,
        ASM.Run,
        ASM.Session,
        ASM.Store,
        ASM.Stream,
        ASM.Tool
      ]
    ]
  end

  defp extras do
    [
      "README.md": [title: "Overview", filename: "overview"],
      "guides/execution-plane-alignment.md": [title: "Execution Plane Alignment"],
      "guides/lane-selection.md": [title: "Lane Selection"],
      "guides/provider-backends.md": [title: "Provider Backends"],
      "guides/inference-endpoints.md": [title: "Inference Endpoints"],
      "guides/common-and-partial-provider-features.md": [
        title: "Common And Partial Provider Features"
      ],
      "guides/provider-sdk-extensions.md": [title: "Provider SDK Extensions"],
      "guides/event-model-and-result-projection.md": [title: "Event Model And Result Projection"],
      "guides/recovery-projection.md": [title: "Recovery Projection"],
      "guides/approvals-and-interrupts.md": [title: "Approvals And Interrupts"],
      "guides/remote-node-execution.md": [title: "Remote Node Execution"],
      "guides/live-adapters.md": [title: "Live Adapters"],
      "guides/boundary-enforcement.md": [title: "Boundary Enforcement"],
      "examples/README.md": [title: "Examples", filename: "examples"],
      "CHANGELOG.md": [title: "Changelog"],
      LICENSE: [title: "License"]
    ]
  end

  defp groups_for_extras do
    [
      "Project Overview": ["README.md"],
      Foundations: [
        "guides/execution-plane-alignment.md",
        "guides/lane-selection.md",
        "guides/provider-backends.md",
        "guides/inference-endpoints.md",
        "guides/common-and-partial-provider-features.md",
        "guides/provider-sdk-extensions.md"
      ],
      Runtime: [
        "guides/event-model-and-result-projection.md",
        "guides/recovery-projection.md",
        "guides/approvals-and-interrupts.md",
        "guides/remote-node-execution.md",
        "guides/live-adapters.md"
      ],
      Examples: ["examples/README.md"],
      Architecture: ["guides/boundary-enforcement.md"],
      Reference: ["CHANGELOG.md", "LICENSE"]
    ]
  end

  defp groups_for_modules do
    [
      "Public API": [
        ASM,
        ASM.Error,
        ASM.Event,
        ASM.History,
        ASM.InferenceEndpoint,
        ASM.Permission,
        ASM.ProviderRegistry,
        ASM.Result,
        ASM.Stream
      ],
      "Inference Endpoint Contracts": [
        ASM.InferenceEndpoint,
        ASM.InferenceEndpoint.BackendManifest,
        ASM.InferenceEndpoint.Compatibility,
        ASM.InferenceEndpoint.CompatibilityResult,
        ASM.InferenceEndpoint.ConsumerManifest,
        ASM.InferenceEndpoint.EndpointDescriptor,
        ASM.InferenceEndpoint.LeaseStore,
        ASM.InferenceEndpoint.Server
      ],
      Backends: [
        ASM.ProviderBackend,
        ASM.ProviderBackend.Event,
        ASM.ProviderBackend.Info,
        ASM.ProviderBackend.Core,
        ASM.ProviderBackend.Proxy,
        ASM.ProviderBackend.SDK,
        ASM.ProviderBackend.SDK.CodexAppServer,
        ASM.ProviderBackend.SdkUnavailableError
      ],
      Providers: [
        ASM.Provider,
        ASM.Provider.ExampleSupport,
        ASM.Provider.Profile,
        ASM.ProviderFeatures,
        ASM.ProviderRegistry,
        ASM.ProviderRuntimeProfile,
        ASM.Options,
        ASM.Options.Amp,
        ASM.Options.Claude,
        ASM.Options.Codex,
        ASM.Options.Gemini,
        ASM.Options.PartialFeatureUnsupportedError,
        ASM.Options.ProviderMismatchError,
        ASM.Options.ProviderNativeOptionError,
        ASM.Options.Shell,
        ASM.Options.UnsupportedExecutionSurfaceError,
        ASM.Options.UnsupportedOptionError,
        ASM.Options.Warning
      ],
      Runtime: [
        ASM.Run.ApprovalCoordinator,
        ASM.Run.EventReducer,
        ASM.Run.Server,
        ASM.Run.State,
        ASM.Run.Supervisor,
        ASM.Session.Continuation,
        ASM.Session.Server,
        ASM.Session.State,
        ASM.Session.Subtree,
        ASM.Session.Supervisor,
        ASM.SessionControl,
        ASM.SessionControl.Entry
      ],
      "Streaming & Tooling": [
        ASM.HostTool,
        ASM.HostTool.Request,
        ASM.HostTool.Response,
        ASM.HostTool.Spec,
        ASM.Store,
        ASM.Store.Memory,
        ASM.Stream,
        ASM.Tool,
        ASM.Tool.Executor,
        ASM.Tool.MCP
      ],
      Pipeline: [
        ASM.Pipeline,
        ASM.Pipeline.CostTracker,
        ASM.Pipeline.Plug,
        ASM.Pipeline.PolicyGuard
      ],
      "Payload Types": [
        ASM.Content,
        ASM.Content.Text,
        ASM.Content.Thinking,
        ASM.Content.ToolResult,
        ASM.Content.ToolUse,
        ASM.Control,
        ASM.Control.ApprovalRequest,
        ASM.Control.ApprovalResolution,
        ASM.Control.CostUpdate,
        ASM.Control.GuardrailTrigger,
        ASM.Control.Raw,
        ASM.Control.RunLifecycle,
        ASM.Message,
        ASM.Message.Assistant,
        ASM.Message.Error,
        ASM.Message.Partial,
        ASM.Message.Raw,
        ASM.Message.Result,
        ASM.Message.System,
        ASM.Message.Thinking,
        ASM.Message.ToolResult,
        ASM.Message.ToolUse,
        ASM.Message.User
      ],
      "Extensions/Persistence": [
        ASM.Extensions.Persistence,
        ASM.Extensions.Persistence.Adapter,
        ASM.Extensions.Persistence.FileStore,
        ASM.Extensions.Persistence.PipelinePlug,
        ASM.Extensions.Persistence.Writer
      ],
      "Extensions/Routing": [
        ASM.Extensions.Routing,
        ASM.Extensions.Routing.HealthTracker,
        ASM.Extensions.Routing.Router,
        ASM.Extensions.Routing.Strategy,
        ASM.Extensions.Routing.Strategy.Priority,
        ASM.Extensions.Routing.Strategy.RoundRobin,
        ASM.Extensions.Routing.Strategy.Weighted
      ],
      "Extensions/Policy": [
        ASM.Extensions.Policy,
        ASM.Extensions.Policy.Enforcer,
        ASM.Extensions.Policy.Violation
      ],
      "Extensions/Rendering": [
        ASM.Extensions.Rendering,
        ASM.Extensions.Rendering.Renderer,
        ASM.Extensions.Rendering.Renderers.Compact,
        ASM.Extensions.Rendering.Renderers.Verbose,
        ASM.Extensions.Rendering.Serializer,
        ASM.Extensions.Rendering.Sink,
        ASM.Extensions.Rendering.Sinks.Callback,
        ASM.Extensions.Rendering.Sinks.File,
        ASM.Extensions.Rendering.Sinks.JSONL,
        ASM.Extensions.Rendering.Sinks.TTY
      ],
      "Extensions/Workspace": [
        ASM.Extensions.Workspace,
        ASM.Extensions.Workspace.Backend,
        ASM.Extensions.Workspace.Diff,
        ASM.Extensions.Workspace.GitBackend,
        ASM.Extensions.Workspace.HashBackend,
        ASM.Extensions.Workspace.Snapshot
      ],
      "Extensions/PubSub": [
        ASM.Extensions.PubSub,
        ASM.Extensions.PubSub.Adapter,
        ASM.Extensions.PubSub.Adapters.Local,
        ASM.Extensions.PubSub.Adapters.Phoenix,
        ASM.Extensions.PubSub.Broadcaster,
        ASM.Extensions.PubSub.Payload,
        ASM.Extensions.PubSub.PipelinePlug,
        ASM.Extensions.PubSub.Topic
      ],
      "Extensions/Provider Native": [
        ASM.Extensions.Provider,
        ASM.Extensions.ProviderSDK,
        ASM.Extensions.ProviderSDK.Amp,
        ASM.Extensions.ProviderSDK.Claude,
        ASM.Extensions.ProviderSDK.Codex,
        ASM.Extensions.ProviderSDK.Derivation,
        ASM.Extensions.ProviderSDK.Dispatch,
        ASM.Extensions.ProviderSDK.Extension,
        ASM.Extensions.ProviderSDK.Gemini,
        ASM.Extensions.ProviderSDK.SessionOptions
      ]
    ]
  end
end

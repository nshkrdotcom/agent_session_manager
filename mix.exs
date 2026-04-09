defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @app :agent_session_manager
  @version "0.9.2"
  @source_url "https://github.com/nshkrdotcom/agent_session_manager"
  @homepage_url "https://hex.pm/packages/agent_session_manager"
  @docs_url "https://hexdocs.pm/agent_session_manager"

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

  defp project_compilers do
    if boundary_checks_enabled?() do
      [:boundary | Mix.compilers()]
    else
      Mix.compilers()
    end
  end

  defp deps do
    [
      {:cli_subprocess_core, "~> 0.1.0"},
      {:boundary, "~> 0.10.4", runtime: false},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:zoi, "~> 0.17"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:nimble_ownership, "~> 1.0", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:supertester, "~> 0.6.0", only: :test}
    ]
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
      "Inference Endpoint Contracts": ~r/^ASM\.InferenceEndpoint/,
      Backends: [ASM.ProviderBackend, ASM.ProviderBackend.Core, ASM.ProviderBackend.SDK],
      Providers: ~r/^ASM\.(Provider|Options)/,
      Runtime: ~r/^ASM\.(Session|Run)/,
      "Streaming & Tooling": ~r/^ASM\.(Store|Tool)/,
      Pipeline: ~r/^ASM\.Pipeline/,
      "Payload Types": ~r/^ASM\.(Content|Message|Control)/,
      "Extensions/Persistence": ~r/^ASM\.Extensions\.Persistence/,
      "Extensions/Routing": ~r/^ASM\.Extensions\.Routing/,
      "Extensions/Policy": ~r/^ASM\.Extensions\.Policy/,
      "Extensions/Rendering": ~r/^ASM\.Extensions\.Rendering/,
      "Extensions/Workspace": ~r/^ASM\.Extensions\.Workspace/,
      "Extensions/PubSub": ~r/^ASM\.Extensions\.PubSub/,
      "Extensions/Provider Native": ~r/^ASM\.Extensions\.Provider(SDK)?/
    ]
  end
end

defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @app :agent_session_manager
  @version "0.10.1"
  @source_url "https://github.com/nshkrdotcom/agent_session_manager"
  @homepage_url "https://hex.pm/packages/agent_session_manager"
  @docs_url "https://hexdocs.pm/agent_session_manager"
  @cli_subprocess_core_requirement "~> 0.1.1"
  @cli_subprocess_core_repo "nshkrdotcom/cli_subprocess_core"

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
    if Mix.env() in [:dev, :test] do
      [:boundary | Mix.compilers()]
    else
      Mix.compilers()
    end
  end

  defp deps do
    workspace_deps() ++
      [
        {:boundary, "~> 0.10.4", only: [:dev, :test], runtime: false},
        {:jason, "~> 1.4"},
        {:nimble_options, "~> 1.1"},
        {:zoi, "~> 0.17"},
        {:telemetry, "~> 1.3"},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
        {:nimble_ownership, "~> 1.0", only: :test},
        {:stream_data, "~> 1.1", only: :test},
        {:mox, "~> 1.2", only: :test},
        {:supertester, "~> 0.6.0", only: :test}
      ]
  end

  defp description do
    "Lean OTP-correct multi-provider CLI session runtime (ASM)."
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts",
      plt_ignore_apps: workspace_apps(),
      paths: [project_ebin_path() | workspace_dialyzer_paths()]
    ]
  end

  defp workspace_deps do
    Enum.map(workspace_dep_specs(), fn {app, path, requirement, opts} ->
      workspace_dep(app, path, requirement, opts)
    end)
  end

  defp workspace_dep_specs do
    [
      {:cli_subprocess_core, "../cli_subprocess_core", @cli_subprocess_core_requirement,
       github: @cli_subprocess_core_repo, branch: "master"}
    ]
  end

  defp workspace_apps do
    Enum.map(workspace_dep_specs(), &elem(&1, 0))
  end

  defp workspace_dialyzer_paths do
    Enum.map(workspace_apps(), fn app ->
      build_ebin_path(app)
    end)
  end

  defp project_ebin_path do
    build_ebin_path(@app)
  end

  defp build_ebin_path(app) when is_atom(app) do
    Path.join(["_build", Atom.to_string(Mix.env()), "lib", Atom.to_string(app), "ebin"])
  end

  defp package do
    [
      name: "agent_session_manager",
      description: description(),
      files: ~w(lib guides assets mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      licenses: ["Apache-2.0"],
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
      main: "readme",
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
      "README.md": [title: "Overview"],
      "guides/lane-selection.md": [title: "Lane Selection"],
      "guides/provider-backends.md": [title: "Provider Backends"],
      "guides/common-and-partial-provider-features.md": [
        title: "Common And Partial Provider Features"
      ],
      "guides/provider-sdk-extensions.md": [title: "Provider SDK Extensions"],
      "guides/event-model-and-result-projection.md": [title: "Event Model And Result Projection"],
      "guides/approvals-and-interrupts.md": [title: "Approvals And Interrupts"],
      "guides/remote-node-execution.md": [title: "Remote Node Execution"],
      "guides/live-adapters.md": [title: "Live Adapters"],
      "guides/boundary-enforcement.md": [title: "Boundary Enforcement"],
      "CHANGELOG.md": [title: "Changelog"],
      LICENSE: [title: "License"]
    ]
  end

  defp groups_for_extras do
    [
      "Project Overview": ["README.md"],
      Foundations: [
        "guides/lane-selection.md",
        "guides/provider-backends.md",
        "guides/common-and-partial-provider-features.md",
        "guides/provider-sdk-extensions.md"
      ],
      Runtime: [
        "guides/event-model-and-result-projection.md",
        "guides/approvals-and-interrupts.md",
        "guides/remote-node-execution.md",
        "guides/live-adapters.md"
      ],
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
        ASM.Permission,
        ASM.ProviderRegistry,
        ASM.Result,
        ASM.Stream
      ],
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

  defp workspace_dep(app, path, requirement, opts) do
    {release_opts, dep_opts} = Keyword.split(opts, [:github, :git, :branch, :tag, :ref])
    expanded_path = Path.expand(path, __DIR__)

    cond do
      hex_packaging?() ->
        {app, requirement, dep_opts}

      workspace_checkout?() and File.dir?(expanded_path) ->
        {app, Keyword.put(dep_opts, :path, path)}

      release_opts != [] ->
        {app, Keyword.merge(dep_opts, release_opts)}

      true ->
        {app, Keyword.put(dep_opts, :path, path)}
    end
  end

  defp hex_packaging? do
    Enum.any?(System.argv(), &String.starts_with?(&1, "hex."))
  end

  defp workspace_checkout? do
    not Enum.member?(Path.split(Path.expand(__DIR__)), "deps")
  end
end

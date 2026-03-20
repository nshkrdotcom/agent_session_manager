defmodule AgentSessionManager.MixProject do
  use Mix.Project

  @version "0.10.0-dev"
  @source_url "https://github.com/nshkrdotcom/agent_session_manager"

  def project do
    [
      app: :agent_session_manager,
      version: @version,
      elixir: "~> 1.18",
      compilers: [:boundary | Mix.compilers()],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ASM",
      source_url: @source_url,
      homepage_url: @source_url
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

  defp deps do
    [
      {:cli_subprocess_core, path: "../cli_subprocess_core"},
      {:claude_agent_sdk, path: "../claude_agent_sdk", optional: true},
      {:codex_sdk, path: "../codex_sdk", optional: true},
      {:gemini_cli_sdk, path: "../gemini_cli_sdk", optional: true},
      {:amp_sdk, path: "../amp_sdk", optional: true},
      {:boundary, path: "vendor/boundary", runtime: false},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:nimble_ownership, "~> 1.0", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:supertester, "~> 0.6.0", only: :test}
    ]
  end

  defp description do
    "Lean OTP-correct multi-provider CLI session runtime (ASM)."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    guides =
      ["guides/*.md", "guides/*.livemd"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()

    [
      main: "readme",
      logo: "assets/agent_session_manager.svg",
      assets: %{"assets" => "assets"},
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"] ++ guides ++ ["CHANGELOG.md", "LICENSE"],
      groups_for_extras: groups_for_extras(guides),
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

  defp groups_for_extras(guides) do
    [
      "Getting Started": ["README.md"],
      Guides: guides,
      Reference: ["CHANGELOG.md", "LICENSE"]
    ]
    |> Enum.reject(fn {_group, entries} -> entries == [] end)
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
      "Extensions/Providers": ~r/^ASM\.Extensions\.Provider/
    ]
  end
end

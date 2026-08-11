defmodule ASM.ReleasePreparationTest do
  use ExUnit.Case, async: true

  alias ASM.Provider

  @repo_root Path.expand("../..", __DIR__)
  @expected_providers [:amp, :antigravity, :claude, :codex, :cursor]

  # Every assertion here used to name a patch version, so an ordinary release
  # left the suite red until someone edited this file — which teaches people to
  # edit this file rather than to read it. What is actually load-bearing is that
  # the version, the docs ref, and the CHANGELOG agree, and that the dependency
  # line has not silently moved.
  test "release metadata is internally consistent and the Elixir floor holds" do
    project = Mix.Project.config()
    changelog = File.read!(Path.join(@repo_root, "CHANGELOG.md"))

    assert project[:elixir] == "~> 1.19"
    assert project[:homepage_url] == "https://hex.pm/packages/agent_session_manager"
    assert project[:docs][:source_ref] == "v#{project[:version]}"

    assert [_, newest] = Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, changelog)
    assert project[:version] == newest
  end

  test "publish mode selects only the CLI core 0.5 line from Hex" do
    publish_deps = DependencySources.deps(@repo_root, publish?: true)

    assert Keyword.fetch!(publish_deps, :cli_subprocess_core) =~ ~r/^~> 0\.5\./
    refute Keyword.has_key?(publish_deps, :cursor_cli_sdk)

    refute inspect(publish_deps) =~ "path:"
    refute inspect(publish_deps) =~ "github:"
  end

  test "package metadata includes the public docs" do
    package = Mix.Project.config()[:package]

    assert package[:name] == "agent_session_manager"
    assert package[:licenses] == ["MIT"]
    assert package[:maintainers] == ["nshkrdotcom"]
    assert package[:links]["GitHub"] == "https://github.com/nshkrdotcom/agent_session_manager"
    assert package[:links]["Hex"] == "https://hex.pm/packages/agent_session_manager"
    assert package[:links]["HexDocs"] == "https://hexdocs.pm/agent_session_manager"

    assert package[:links]["License"] ==
             "https://github.com/nshkrdotcom/agent_session_manager/blob/main/LICENSE"

    for required <-
          ~w(lib assets mix.exs README.md CHANGELOG.md LICENSE guides examples/README.md) do
      assert required in package[:files]
    end

    refute ".formatter.exs" in package[:files]

    # 0.12.2 shipped `build_support/`, and `mix.exs` requires that file when it
    # is present — so a consumer resolving the package either failed to load the
    # project or received git dependencies instead of Hex ones. Its absence is
    # now the signal that tells `mix.exs` it is running inside a consumer's
    # deps/, so shipping it again re-breaks every downstream package.
    refute "build_support" in package[:files]
  end

  test "README and HexDocs use the named 200px release asset" do
    project = Mix.Project.config()
    readme = File.read!(Path.join(@repo_root, "README.md"))
    header = readme |> String.split("\n") |> Enum.take(24) |> Enum.join("\n")

    assert project[:docs][:assets] == %{"assets" => "assets"}
    assert project[:docs][:logo] == "assets/agent_session_manager.svg"
    assert header =~ ~s(src="assets/agent_session_manager.svg")
    assert header =~ ~s(width="200")
    assert header =~ ~s(href="https://github.com/nshkrdotcom/agent_session_manager")
    assert header =~ ~s(href="LICENSE")
    assert length(Regex.scan(~r/img\.shields\.io/, header)) == 2
  end

  test "the provider set is closed and Antigravity owns Google coding-agent support" do
    assert Enum.sort(Provider.supported_providers()) == @expected_providers
    assert {:ok, antigravity} = Provider.resolve(:antigravity)
    assert antigravity.sdk_runtime == :"Elixir.AntigravityCliSdk.Runtime.CLI"

    assert {:error, error} = Provider.resolve(:gemini)
    assert error.kind == :config_invalid
  end

  test "public implementation uses CLI core facades without raw Execution Plane leakage" do
    for path <- Path.wildcard(Path.join(@repo_root, "lib/**/*.ex")) do
      source = File.read!(path)
      relative = Path.relative_to(path, @repo_root)

      refute source =~ "ExecutionPlane.", "raw Execution Plane reference in #{relative}"

      for call <- ~w(System.get_env System.fetch_env System.put_env System.delete_env) do
        refute source =~ call, "runtime OS environment call #{call} in #{relative}"
      end
    end
  end

  test "release docs state the five-provider and Google SDK boundaries" do
    readme = File.read!(Path.join(@repo_root, "README.md"))
    changelog = File.read!(Path.join(@repo_root, "CHANGELOG.md"))
    features = File.read!(Path.join(@repo_root, "guides/common-and-partial-provider-features.md"))
    backends = File.read!(Path.join(@repo_root, "guides/provider-backends.md"))

    assert readme =~ "five first-party CLI providers"
    assert readme =~ "Antigravity is the current Google coding-agent SDK"
    assert readme =~ "`gemini_ex` is a distinct model API SDK"
    assert readme =~ ~s({:claude_agent_sdk, "~> 0.19.0", optional: true})
    assert readme =~ ~s({:codex_sdk, "~> 0.18.0", optional: true})
    assert readme =~ ~s({:amp_sdk, "~> 0.7.0", optional: true})
    assert readme =~ ~s({:antigravity_cli_sdk, "~> 0.2.0", optional: true})
    assert readme =~ "`cursor_cli_sdk 0.2.0` cannot be combined"
    assert changelog =~ "## [0.12.1] - 2026-07-27"

    refute features =~ "across six providers"
    refute backends =~ "sixth first-party provider"
  end
end

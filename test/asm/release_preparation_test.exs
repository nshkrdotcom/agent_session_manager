defmodule ASM.ReleasePreparationTest do
  use ExUnit.Case, async: true

  alias ASM.Provider

  @repo_root Path.expand("../..", __DIR__)
  @expected_providers [:amp, :antigravity, :claude, :codex, :cursor]

  test "0.10.0 release metadata and Elixir floor are frozen" do
    project = Mix.Project.config()

    assert project[:version] == "0.10.0"
    assert project[:elixir] == "~> 1.19"
    assert project[:docs][:source_ref] == "v0.10.0"
    assert project[:homepage_url] == "https://hex.pm/packages/agent_session_manager"
  end

  test "publish mode selects CLI core 0.2 and Cursor 0.1 from Hex" do
    publish_deps = DependencySources.deps(@repo_root, publish?: true)

    assert Keyword.fetch!(publish_deps, :cli_subprocess_core) == "~> 0.2.0"
    assert Keyword.fetch!(publish_deps, :cursor_cli_sdk) == "~> 0.1.0"

    refute inspect(publish_deps) =~ "path:"
    refute inspect(publish_deps) =~ "github:"
  end

  test "package metadata includes the public docs and dependency helper" do
    package = Mix.Project.config()[:package]

    assert package[:name] == "agent_session_manager"
    assert package[:licenses] == ["MIT"]
    assert package[:maintainers] == ["nshkrdotcom"]
    assert package[:links]["GitHub"] == "https://github.com/nshkrdotcom/agent_session_manager"
    assert package[:links]["Hex"] == "https://hex.pm/packages/agent_session_manager"
    assert package[:links]["HexDocs"] == "https://hexdocs.pm/agent_session_manager"

    for required <- ~w(lib assets build_support mix.exs README.md CHANGELOG.md LICENSE guides) do
      assert required in package[:files]
    end
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
    assert readme =~ ~s({:claude_agent_sdk, "~> 0.18.0", optional: true})
    assert readme =~ ~s({:amp_sdk, "~> 0.6.0", optional: true})
    assert changelog =~ "## [0.10.0] - 2026-07-13"

    refute features =~ "across six providers"
    refute backends =~ "sixth first-party provider"
  end
end

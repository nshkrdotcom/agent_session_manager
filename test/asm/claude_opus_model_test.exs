defmodule ASM.ClaudeOpusModelTest do
  @moduledoc """
  Regression guard: Claude models must stay resolvable through the ASM Claude lane via
  the shared `CliSubprocessCore.ModelRegistry` catalog.

  ASM deliberately keeps no model catalog of its own — it inherits the lineup
  transitively from `cli_subprocess_core` — so the only parity this repo owns is
  that the shared catalog's current defaults and pinned model IDs resolve here.
  """
  use ExUnit.Case, async: true

  alias ASM.Options

  describe "opus resolution through finalize_provider_opts/2" do
    test "opus resolves from the shared catalog (no allow_unknown_model needed)" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "opus")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "opus"
      assert payload.model_family == "claude"
      assert payload.model_source == :catalog
      refute Map.get(payload.extra, "unregistered")
    end

    test "a pinned Opus 5 model ID does not drift with the alias" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "claude-opus-5")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.requested_model == "claude-opus-5"
      assert payload.model_source == :catalog
      assert payload.resolved_model == "claude-opus-5"
      refute Map.get(payload.extra, "unregistered")
    end

    test "the 1M-context Opus id resolves as its own catalog entry" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "opus[1m]")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "opus[1m]"
      assert payload.model_source == :catalog
    end

    test "Claude reasoning effort is resolved by the shared catalog" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:claude,
                 model: "opus",
                 reasoning_effort: :xhigh
               )

      assert Keyword.fetch!(attrs, :model_payload).reasoning == "xhigh"
    end
  end

  test "current Claude Code model IDs and default effort flow through ASM" do
    assert {:ok, default} = Options.resolve_model_payload(:claude, [])
    assert default.resolved_model == "sonnet"
    assert default.reasoning == "medium"

    for model <- ~w(claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-2) do
      assert {:ok, payload} = Options.resolve_model_payload(:claude, model: model)
      assert payload.resolved_model == model
      assert payload.reasoning == "medium"
    end
  end

  test "ASM ships no model catalog of its own" do
    repo_root = Path.expand("../..", __DIR__)

    assert Path.wildcard(Path.join(repo_root, "priv/models/*")) == [],
           "ASM must consume the shared cli_subprocess_core catalog, not grow a second one"
  end
end

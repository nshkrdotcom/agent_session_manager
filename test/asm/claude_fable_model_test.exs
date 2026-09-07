defmodule ASM.ClaudeFableModelTest do
  @moduledoc """
  Regression guard: `fable` (Claude Fable 5) must stay resolvable through the
  ASM Claude lane via the shared `CliSubprocessCore.ModelRegistry` catalog.
  ASM inherits the model lineup transitively from cli_subprocess_core, so a
  stale or regressed registry would otherwise break fable selection silently.
  """
  use ExUnit.Case, async: true

  alias ASM.Options

  describe "fable resolution through finalize_provider_opts/2" do
    test "fable resolves from the shared catalog (no allow_unknown_model needed)" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "fable")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "fable"
      assert payload.model_family == "claude"
      assert payload.model_source == :catalog
      refute Map.get(payload.extra, "unregistered")
    end

    test "the claude-fable-5 alias resolves to the canonical fable id" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "claude-fable-5")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.requested_model == "claude-fable-5"
      assert payload.resolved_model == "fable"
      assert payload.model_source == :catalog
    end

    test "claude-fable-5-1 and fable-5.1 resolve to the canonical fable id" do
      for alias_name <- ~w(claude-fable-5-1 fable-5.1 fable-5-1) do
        assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: alias_name)

        payload = Keyword.fetch!(attrs, :model_payload)
        assert payload.requested_model == alias_name
        assert payload.resolved_model == "fable"
        assert payload.model_source == :catalog
      end
    end

    test "claude-mythos-5-1 resolves to mythos-5.1 under restricted visibility" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "claude-mythos-5-1")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.requested_model == "claude-mythos-5-1"
      assert payload.resolved_model == "claude-mythos-5-1"
      assert payload.visibility == :restricted
    end
  end
end

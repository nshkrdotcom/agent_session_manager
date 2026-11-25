defmodule ASM.ClaudeFableModelTest do
  @moduledoc """
  Regression guard: current and pinned Fable models must stay resolvable through the
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
      assert payload.reasoning == "medium"
      refute Map.get(payload.extra, "unregistered")
    end

    test "the claude-fable-5 alias resolves to the pinned claude-fable-5 id" do
      assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: "claude-fable-5")

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.requested_model == "claude-fable-5"
      assert payload.resolved_model == "claude-fable-5"
      assert payload.model_source == :catalog
    end

    test "claude-fable-5-1 and fable-5.1 resolve to the pinned claude-fable-5-1 id" do
      for alias_name <- ~w(claude-fable-5-1 fable-5.1 fable-5-1) do
        assert {:ok, attrs} = Options.finalize_provider_opts(:claude, model: alias_name)

        payload = Keyword.fetch!(attrs, :model_payload)
        assert payload.requested_model == alias_name
        assert payload.resolved_model == "claude-fable-5-1"
        assert payload.model_source == :catalog
      end
    end

    test "Mythos IDs resolve with restricted visibility" do
      for model <- ~w(claude-mythos-5-1 claude-mythos-5-2) do
        assert {:ok, payload} = Options.resolve_model_payload(:claude, model: model)
        assert payload.requested_model == model
        assert payload.resolved_model == model
        assert payload.visibility == :restricted
      end
    end
  end
end

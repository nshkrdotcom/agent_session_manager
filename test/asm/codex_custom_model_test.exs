defmodule ASM.CodexCustomModelTest do
  @moduledoc """
  ASM callers can select a Codex model newer than the shared registry via the
  `allow_unknown_model` provider option, which threads the core
  `CliSubprocessCore.ModelRegistry` `allow_unknown` pass-through. Default
  behavior (flag absent) stays strict-reject.

  This mirrors `ASM.ClaudeCustomModelTest` - `allow_unknown_model` is a
  common provider option (see `ASM.Schema.ProviderOptions.@common_fields`
  and `ASM.Options.normalize_model_input/3`), not a Claude-specific one, so
  every ASM-supported provider gets the same behavior.
  """
  use ExUnit.Case, async: true

  alias ASM.Options

  describe "finalize_provider_opts/3 model resolution" do
    test "allow_unknown_model passes an unregistered Codex model through" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.9-not-yet-released",
                 allow_unknown_model: true
               )

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "gpt-5.9-not-yet-released"
      assert payload.extra["unregistered"] == true

      # The ASM-facing / core flags must not linger in the finalized attrs.
      refute Keyword.has_key?(attrs, :allow_unknown_model)
      refute Keyword.has_key?(attrs, :allow_unknown)
    end

    test "an unregistered Codex model is rejected by default" do
      assert {:error, %ASM.Error{}} =
               Options.finalize_provider_opts(:codex, model: "gpt-5.9-not-yet-released")
    end

    test "known Codex aliases still resolve normally" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.4",
                 allow_unknown_model: true
               )

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "gpt-5.4"
      refute Map.get(payload.extra, "unregistered")
    end
  end

  describe "provider options schema" do
    test "allow_unknown_model is a recognized Codex provider option" do
      assert Keyword.has_key?(ASM.Options.Codex.schema(), :allow_unknown_model)
    end

    test "allow_unknown_model is recognized for every ASM provider schema" do
      for {provider_mod, provider} <- [
            {ASM.Options.Codex, :codex},
            {ASM.Options.Gemini, :gemini},
            {ASM.Options.Amp, :amp},
            {ASM.Options.Antigravity, :antigravity},
            {ASM.Options.Cursor, :cursor}
          ] do
        assert Keyword.has_key?(provider_mod.schema(), :allow_unknown_model),
               "expected #{inspect(provider)} provider schema to declare allow_unknown_model"
      end
    end
  end
end

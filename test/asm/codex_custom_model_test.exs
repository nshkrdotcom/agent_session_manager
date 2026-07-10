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
  alias ASM.Options.{Amp, Antigravity, Codex, Cursor}

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

    test "current GPT-5.6 Codex models resolve without compatibility aliases" do
      for model <- ~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna) do
        assert {:ok, attrs} =
                 Options.finalize_provider_opts(:codex,
                   model: model,
                   allow_unknown_model: true
                 )

        payload = Keyword.fetch!(attrs, :model_payload)
        assert payload.resolved_model == model
        refute Map.get(payload.extra, "unregistered")
      end

      assert {:error, %ASM.Error{}} =
               Options.finalize_provider_opts(:codex, model: "gpt-5.6")
    end

    test "Spark resolves strictly with its live default reasoning" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.3-codex-spark"
               )

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "gpt-5.3-codex-spark"
      assert payload.reasoning == "high"
      refute Map.get(payload.extra, "unregistered")
    end

    test "delegates GPT-5.6 max and ultra boundaries to the shared core" do
      assert {:ok, sol} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.6-sol",
                 reasoning_effort: :max
               )

      assert Keyword.fetch!(sol, :model_payload).reasoning == "max"

      assert {:ok, terra} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.6-terra",
                 reasoning_effort: :ultra
               )

      assert Keyword.fetch!(terra, :model_payload).reasoning == "ultra"

      assert {:error, %ASM.Error{message: message}} =
               Options.finalize_provider_opts(:codex,
                 model: "gpt-5.6-luna",
                 reasoning_effort: :ultra
               )

      assert message =~ "invalid_reasoning_effort"
    end
  end

  describe "provider options schema" do
    test "allow_unknown_model is a recognized Codex provider option" do
      assert Keyword.has_key?(Codex.schema(), :allow_unknown_model)
    end

    test "allow_unknown_model is recognized for every ASM provider schema" do
      for {provider_mod, provider} <- [
            {Codex, :codex},
            {Amp, :amp},
            {Antigravity, :antigravity},
            {Cursor, :cursor}
          ] do
        assert Keyword.has_key?(provider_mod.schema(), :allow_unknown_model),
               "expected #{inspect(provider)} provider schema to declare allow_unknown_model"
      end
    end

    test "Codex schema admits the current max and ultra effort atoms" do
      for effort <- [:max, :ultra] do
        assert {:ok, validated} =
                 Options.validate(
                   [provider: :codex, model: "gpt-5.6-sol", reasoning_effort: effort],
                   Codex.schema()
                 )

        assert validated[:reasoning_effort] == effort
      end
    end
  end
end

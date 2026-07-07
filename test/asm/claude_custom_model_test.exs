defmodule ASM.ClaudeCustomModelTest do
  @moduledoc """
  ASM callers can select a Claude model newer than the shared registry via the
  `allow_unknown_model` provider option, which threads the core
  `CliSubprocessCore.ModelRegistry` `allow_unknown` pass-through. Default
  behavior (flag absent) stays strict-reject.
  """
  use ExUnit.Case, async: true

  alias ASM.Options
  alias ASM.Options.Claude

  describe "finalize_provider_opts/3 model resolution" do
    test "allow_unknown_model passes an unregistered Claude model through" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:claude,
                 model: "claude-brand-new-2027",
                 allow_unknown_model: true
               )

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "claude-brand-new-2027"
      assert payload.extra["unregistered"] == true

      # The ASM-facing / core flags must not linger in the finalized attrs.
      refute Keyword.has_key?(attrs, :allow_unknown_model)
      refute Keyword.has_key?(attrs, :allow_unknown)
    end

    test "an unregistered Claude model is rejected by default" do
      assert {:error, %ASM.Error{}} =
               Options.finalize_provider_opts(:claude, model: "claude-brand-new-2027")
    end

    test "known Claude aliases still resolve normally" do
      assert {:ok, attrs} =
               Options.finalize_provider_opts(:claude,
                 model: "haiku",
                 allow_unknown_model: true
               )

      payload = Keyword.fetch!(attrs, :model_payload)
      assert payload.resolved_model == "haiku"
      refute Map.get(payload.extra, "unregistered")
    end
  end

  describe "provider options schema" do
    test "allow_unknown_model is a recognized Claude provider option" do
      assert Keyword.has_key?(Claude.schema(), :allow_unknown_model)
    end
  end
end

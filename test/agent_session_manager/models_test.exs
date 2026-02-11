defmodule AgentSessionManager.ModelsTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Models

  describe "default_model/1" do
    test "returns claude default model" do
      assert Models.default_model(:claude) == "claude-haiku-4-5-20251001"
    end

    test "returns nil for codex (SDK selects its own default)" do
      assert Models.default_model(:codex) == nil
    end

    test "returns nil for amp (SDK selects its own default)" do
      assert Models.default_model(:amp) == nil
    end

    test "returns nil for unknown provider" do
      assert Models.default_model(:unknown) == nil
    end
  end

  describe "default_pricing_table/0" do
    test "returns a map with claude, codex, and amp providers" do
      table = Models.default_pricing_table()
      assert is_map(table)
      assert Map.has_key?(table, "claude")
      assert Map.has_key?(table, "codex")
      assert Map.has_key?(table, "amp")
    end

    test "claude provider has default rates and model-specific rates" do
      %{"claude" => claude} = Models.default_pricing_table()
      assert %{input: _, output: _} = claude.default
      assert Map.has_key?(claude.models, "claude-opus-4-6")
      assert Map.has_key?(claude.models, "claude-sonnet-4-5")
      assert Map.has_key?(claude.models, "claude-haiku-4-5")
    end

    test "claude opus model has cache rates" do
      %{"claude" => claude} = Models.default_pricing_table()
      opus = claude.models["claude-opus-4-6"]
      assert Map.has_key?(opus, :input)
      assert Map.has_key?(opus, :output)
      assert Map.has_key?(opus, :cache_read)
      assert Map.has_key?(opus, :cache_creation)
    end

    test "codex provider has default rates and model-specific rates" do
      %{"codex" => codex} = Models.default_pricing_table()
      assert %{input: _, output: _} = codex.default
      assert Map.has_key?(codex.models, "o3")
      assert Map.has_key?(codex.models, "o3-mini")
      assert Map.has_key?(codex.models, "gpt-4o")
      assert Map.has_key?(codex.models, "gpt-4o-mini")
    end

    test "amp provider has default rates" do
      %{"amp" => amp} = Models.default_pricing_table()
      assert %{input: _, output: _} = amp.default
    end
  end

  describe "pricing_table/0" do
    test "returns default pricing table when no application config is set" do
      assert Models.pricing_table() == Models.default_pricing_table()
    end
  end

  describe "model_names/0" do
    test "returns all known model name keys" do
      names = Models.model_names()
      assert is_list(names)
      assert "claude-opus-4-6" in names
      assert "claude-sonnet-4-5" in names
      assert "claude-haiku-4-5" in names
      assert "o3" in names
      assert "o3-mini" in names
      assert "gpt-4o" in names
      assert "gpt-4o-mini" in names
    end
  end
end

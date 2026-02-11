defmodule AgentSessionManager.Cost.CostCalculatorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Cost.CostCalculator

  @pricing_table %{
    "claude" => %{
      default: %{input: 0.000003, output: 0.000015},
      models: %{
        "claude-opus-4-6" => %{
          input: 0.000015,
          output: 0.000075,
          cache_read: 0.0000015,
          cache_creation: 0.00001875
        },
        "claude-sonnet-4-5" => %{
          input: 0.000003,
          output: 0.000015,
          cache_read: 0.0000003,
          cache_creation: 0.00000375
        },
        "claude-haiku-4-5" => %{
          input: 0.0000008,
          output: 0.000004,
          cache_read: 0.00000008,
          cache_creation: 0.000001
        }
      }
    },
    "codex" => %{
      default: %{input: 0.000003, output: 0.000015},
      models: %{
        "o3" => %{input: 0.000010, output: 0.000040},
        "o3-mini" => %{input: 0.0000011, output: 0.0000044},
        "gpt-4o" => %{input: 0.0000025, output: 0.000010},
        "gpt-4o-mini" => %{input: 0.00000015, output: 0.0000006}
      }
    },
    "amp" => %{
      default: %{input: 0.000003, output: 0.000015},
      models: %{}
    }
  }

  describe "calculate/4" do
    test "exact model match returns correct cost" do
      tokens = %{input_tokens: 1000, output_tokens: 500}

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", "claude-opus-4-6", @pricing_table)

      expected = 1000 * 0.000015 + 500 * 0.000075
      assert_in_delta cost, expected, 0.0000001
    end

    test "prefix model match strips date suffix" do
      tokens = %{input_tokens: 1000, output_tokens: 500}

      assert {:ok, cost} =
               CostCalculator.calculate(
                 tokens,
                 "claude",
                 "claude-sonnet-4-5-20250929",
                 @pricing_table
               )

      expected = 1000 * 0.000003 + 500 * 0.000015
      assert_in_delta cost, expected, 0.0000001
    end

    test "provider default fallback when model is nil" do
      tokens = %{input_tokens: 1000, output_tokens: 500}

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", nil, @pricing_table)

      expected = 1000 * 0.000003 + 500 * 0.000015
      assert_in_delta cost, expected, 0.0000001
    end

    test "provider default fallback when model has no match" do
      tokens = %{input_tokens: 1000, output_tokens: 500}

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", "claude-unknown-model", @pricing_table)

      expected = 1000 * 0.000003 + 500 * 0.000015
      assert_in_delta cost, expected, 0.0000001
    end

    test "unknown provider returns error" do
      tokens = %{input_tokens: 1000, output_tokens: 500}

      assert {:error, :no_rates} =
               CostCalculator.calculate(tokens, "unknown", nil, @pricing_table)
    end

    test "cache tokens at reduced/elevated rates" do
      tokens = %{
        input_tokens: 1000,
        output_tokens: 500,
        cache_read_tokens: 800,
        cache_creation_tokens: 200
      }

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", "claude-opus-4-6", @pricing_table)

      expected =
        1000 * 0.000015 + 500 * 0.000075 +
          800 * 0.0000015 + 200 * 0.00001875

      assert_in_delta cost, expected, 0.0000001
    end

    test "cache tokens fall back to input rate when cache rate not defined" do
      tokens = %{
        input_tokens: 1000,
        output_tokens: 500,
        cache_read_tokens: 800
      }

      # Codex o3 has no cache_read rate defined
      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "codex", "o3", @pricing_table)

      # cache_read falls back to input rate
      expected = 1000 * 0.000010 + 500 * 0.000040 + 800 * 0.000010
      assert_in_delta cost, expected, 0.0000001
    end

    test "zero tokens returns zero cost" do
      tokens = %{input_tokens: 0, output_tokens: 0}

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", "claude-opus-4-6", @pricing_table)

      assert_in_delta cost, 0.0, 0.0000001
    end

    test "missing token fields default to zero" do
      tokens = %{output_tokens: 500}

      assert {:ok, cost} =
               CostCalculator.calculate(tokens, "claude", "claude-opus-4-6", @pricing_table)

      expected = 500 * 0.000075
      assert_in_delta cost, expected, 0.0000001
    end

    test "empty token map returns zero cost" do
      assert {:ok, cost} =
               CostCalculator.calculate(%{}, "claude", "claude-opus-4-6", @pricing_table)

      assert_in_delta cost, 0.0, 0.0000001
    end
  end

  describe "resolve_rates/3" do
    test "exact model match" do
      assert {:ok, rates} =
               CostCalculator.resolve_rates("claude", "claude-opus-4-6", @pricing_table)

      assert rates.input == 0.000015
      assert rates.output == 0.000075
      assert rates.cache_read == 0.0000015
    end

    test "prefix match" do
      assert {:ok, rates} =
               CostCalculator.resolve_rates(
                 "claude",
                 "claude-haiku-4-5-20251001",
                 @pricing_table
               )

      assert rates.input == 0.0000008
    end

    test "provider default" do
      assert {:ok, rates} = CostCalculator.resolve_rates("amp", nil, @pricing_table)
      assert rates.input == 0.000003
    end

    test "unknown provider" do
      assert {:error, :no_rates} = CostCalculator.resolve_rates("unknown", nil, @pricing_table)
    end
  end

  describe "calculate_run_cost/2" do
    test "calculates cost from Run struct" do
      run = %AgentSessionManager.Core.Run{
        id: "run-1",
        session_id: "ses-1",
        status: :completed,
        provider: "claude",
        provider_metadata: %{model: "claude-sonnet-4-5"},
        token_usage: %{input_tokens: 2000, output_tokens: 1000},
        started_at: DateTime.utc_now()
      }

      assert {:ok, cost} = CostCalculator.calculate_run_cost(run, @pricing_table)
      expected = 2000 * 0.000003 + 1000 * 0.000015
      assert_in_delta cost, expected, 0.0000001
    end

    test "returns error when provider has no rates" do
      run = %AgentSessionManager.Core.Run{
        id: "run-1",
        session_id: "ses-1",
        status: :completed,
        provider: "unknown",
        provider_metadata: %{},
        token_usage: %{input_tokens: 100, output_tokens: 50},
        started_at: DateTime.utc_now()
      }

      assert {:error, :no_rates} = CostCalculator.calculate_run_cost(run, @pricing_table)
    end

    test "handles nil provider gracefully" do
      run = %AgentSessionManager.Core.Run{
        id: "run-1",
        session_id: "ses-1",
        status: :completed,
        provider: nil,
        provider_metadata: %{},
        token_usage: %{input_tokens: 100, output_tokens: 50},
        started_at: DateTime.utc_now()
      }

      assert {:error, :no_rates} = CostCalculator.calculate_run_cost(run, @pricing_table)
    end
  end

  describe "normalize_legacy_rates/1" do
    test "converts flat provider rates to pricing table format" do
      legacy = %{"claude" => %{input: 0.000003, output: 0.000015}}

      result = CostCalculator.normalize_legacy_rates(legacy)

      assert %{"claude" => %{default: %{input: 0.000003, output: 0.000015}, models: %{}}} =
               result
    end

    test "passes through already-structured pricing table unchanged" do
      assert @pricing_table == CostCalculator.normalize_legacy_rates(@pricing_table)
    end
  end

  describe "default_pricing_table/0" do
    test "returns a non-empty pricing table" do
      table = CostCalculator.default_pricing_table()
      assert is_map(table)
      assert Map.has_key?(table, "claude")
      assert Map.has_key?(table, "codex")
      assert Map.has_key?(table, "amp")
    end
  end
end

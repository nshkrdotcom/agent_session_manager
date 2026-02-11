defmodule AgentSessionManager.Models do
  @moduledoc """
  Central registry of model identifiers, default models, and pricing data.

  All model name strings and per-token rates are defined here so that updating
  a model version or price is a single-file change. Adapters and cost calculators
  reference this module rather than hardcoding model strings.

  ## Application Configuration

  Defaults can be overridden via application config:

      config :agent_session_manager, AgentSessionManager.Models,
        claude_default_model: "claude-sonnet-4-5-20250929",
        pricing_table: %{...}

  See the [Model Configuration guide](model_configuration.md) for details.
  """

  # -- Default models per provider -----------------------------------------------

  @claude_default_model "claude-haiku-4-5-20251001"

  # -- Default pricing table -----------------------------------------------------

  @default_pricing_table %{
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

  # -- Public API ----------------------------------------------------------------

  @doc """
  Returns the default model for the given provider.

  ## Examples

      iex> AgentSessionManager.Models.default_model(:claude)
      "claude-haiku-4-5-20251001"

      iex> AgentSessionManager.Models.default_model(:codex)
      nil

  """
  @spec default_model(atom()) :: String.t() | nil
  def default_model(:claude) do
    app_config(:claude_default_model, @claude_default_model)
  end

  def default_model(_provider), do: nil

  @doc """
  Returns the compiled default pricing table (not affected by app config).
  """
  @spec default_pricing_table() :: map()
  def default_pricing_table, do: @default_pricing_table

  @doc """
  Returns the active pricing table, merging any application config overrides.
  """
  @spec pricing_table() :: map()
  def pricing_table do
    app_config(:pricing_table, @default_pricing_table)
  end

  @doc """
  Returns a list of all known model name keys from the default pricing table.
  """
  @spec model_names() :: [String.t()]
  def model_names do
    @default_pricing_table
    |> Enum.flat_map(fn {_provider, %{models: models}} -> Map.keys(models) end)
    |> Enum.sort()
  end

  # -- Private ------------------------------------------------------------------

  defp app_config(key, default) do
    :agent_session_manager
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end

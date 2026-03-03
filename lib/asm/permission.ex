defmodule ASM.Permission do
  @moduledoc """
  Normalizes permission modes into a common runtime model.

  Normalized set:

  - `:default`
  - `:auto`
  - `:bypass`
  - `:plan`
  """

  alias ASM.Error

  @type provider :: :claude | :codex | :codex_exec | :gemini | atom()
  @type normalized_mode :: :default | :auto | :bypass | :plan
  @type native_mode :: atom()
  @type normalization :: %{normalized: normalized_mode(), native: native_mode()}

  @normalized_modes [:default, :auto, :bypass, :plan]

  @string_modes %{
    "default" => :default,
    "auto" => :auto,
    "bypass" => :bypass,
    "plan" => :plan,
    "accept_edits" => :accept_edits,
    "bypass_permissions" => :bypass_permissions,
    "delegate" => :delegate,
    "dont_ask" => :dont_ask,
    "auto_edit" => :auto_edit,
    "yolo" => :yolo
  }

  @spec normalized_modes() :: [normalized_mode()]
  def normalized_modes, do: @normalized_modes

  @spec valid_modes(provider()) :: [atom()]
  def valid_modes(provider) do
    provider
    |> canonical_provider()
    |> provider_mode_map()
    |> Map.keys()
  end

  @spec normalize(provider(), atom() | String.t()) :: {:ok, normalization()} | {:error, Error.t()}
  def normalize(provider, mode) do
    provider = canonical_provider(provider)

    with {:ok, mode_atom} <- normalize_mode_atom(mode) do
      normalize_for_provider(provider, mode_atom)
    end
  end

  @spec normalize!(provider(), atom() | String.t()) :: normalization()
  def normalize!(provider, mode) do
    case normalize(provider, mode) do
      {:ok, normalized} ->
        normalized

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec canonical_provider(provider()) :: provider()
  def canonical_provider(:codex), do: :codex_exec
  def canonical_provider(provider), do: provider

  defp normalize_mode_atom(mode) when is_atom(mode), do: {:ok, mode}

  defp normalize_mode_atom(mode) when is_binary(mode) do
    normalized =
      mode
      |> String.trim()
      |> String.downcase()
      |> then(&Map.get(@string_modes, &1))

    if normalized do
      {:ok, normalized}
    else
      {:error, config_error("Unsupported permission mode: #{inspect(mode)}")}
    end
  end

  defp normalize_mode_atom(other) do
    {:error, config_error("Invalid permission mode type: #{inspect(other)}")}
  end

  defp normalize_for_provider(provider, mode_atom) do
    case Map.fetch(provider_mode_map(provider), mode_atom) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error,
         config_error(
           "Permission mode #{inspect(mode_atom)} is not valid for provider #{inspect(provider)}",
           provider: provider,
           mode: mode_atom
         )}
    end
  end

  defp provider_mode_map(:claude) do
    %{
      default: %{normalized: :default, native: :default},
      auto: %{normalized: :auto, native: :accept_edits},
      accept_edits: %{normalized: :auto, native: :accept_edits},
      delegate: %{normalized: :auto, native: :delegate},
      dont_ask: %{normalized: :auto, native: :dont_ask},
      bypass: %{normalized: :bypass, native: :bypass_permissions},
      bypass_permissions: %{normalized: :bypass, native: :bypass_permissions},
      plan: %{normalized: :plan, native: :plan}
    }
  end

  defp provider_mode_map(:codex_exec) do
    %{
      default: %{normalized: :default, native: :default},
      auto: %{normalized: :auto, native: :auto_edit},
      auto_edit: %{normalized: :auto, native: :auto_edit},
      bypass: %{normalized: :bypass, native: :yolo},
      yolo: %{normalized: :bypass, native: :yolo},
      plan: %{normalized: :plan, native: :plan}
    }
  end

  defp provider_mode_map(:gemini) do
    %{
      default: %{normalized: :default, native: :default},
      auto: %{normalized: :auto, native: :auto_edit},
      auto_edit: %{normalized: :auto, native: :auto_edit},
      bypass: %{normalized: :bypass, native: :yolo},
      yolo: %{normalized: :bypass, native: :yolo},
      plan: %{normalized: :plan, native: :plan}
    }
  end

  defp provider_mode_map(_other) do
    %{
      default: %{normalized: :default, native: :default},
      auto: %{normalized: :auto, native: :auto},
      bypass: %{normalized: :bypass, native: :bypass},
      plan: %{normalized: :plan, native: :plan}
    }
  end

  defp config_error(message, details \\ %{}) do
    Error.new(:config_invalid, :config, message, cause: details)
  end
end

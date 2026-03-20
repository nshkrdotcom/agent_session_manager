defmodule ASM.Provider.Profile do
  @moduledoc """
  Session admission defaults for a provider.
  """

  alias ASM.Error

  defstruct max_concurrent_runs: 1,
            max_queued_runs: 10

  @type t :: %__MODULE__{
          max_concurrent_runs: pos_integer(),
          max_queued_runs: non_neg_integer()
        }

  @spec schema() :: keyword()
  def schema do
    [
      max_concurrent_runs: [type: :pos_integer, default: 1],
      max_queued_runs: [type: :non_neg_integer, default: 10]
    ]
  end

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs), do: attrs |> Map.to_list() |> new()

  def new(attrs) when is_list(attrs) do
    case NimbleOptions.validate(attrs, schema()) do
      {:ok, validated} ->
        {:ok, struct!(__MODULE__, validated)}

      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, Error.new(:config_invalid, :config, Exception.message(error), cause: error)}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} ->
        profile

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end
end

defmodule ASM.Provider.Profile do
  @moduledoc """
  Runtime transport/session profile for a provider.
  """

  alias ASM.Error

  @enforce_keys [:transport_mode, :input_mode, :control_mode, :session_mode]
  defstruct [
    :transport_mode,
    :input_mode,
    :control_mode,
    :session_mode,
    transport_restart: :temporary,
    max_concurrent_runs: 1,
    max_queued_runs: 10
  ]

  @type transport_mode :: :persistent_stdio | :exec_stdio | :json_rpc
  @type input_mode :: :stdin | :flag
  @type control_mode :: :none | :stdio_bidirectional
  @type session_mode :: :provider_managed | :asm_managed
  @type transport_restart :: :transient | :temporary

  @type t :: %__MODULE__{
          transport_mode: transport_mode(),
          input_mode: input_mode(),
          control_mode: control_mode(),
          session_mode: session_mode(),
          transport_restart: transport_restart(),
          max_concurrent_runs: pos_integer(),
          max_queued_runs: non_neg_integer()
        }

  @spec schema() :: keyword()
  def schema do
    [
      transport_mode: [type: {:in, [:persistent_stdio, :exec_stdio, :json_rpc]}, required: true],
      input_mode: [type: {:in, [:stdin, :flag]}, required: true],
      control_mode: [type: {:in, [:none, :stdio_bidirectional]}, required: true],
      session_mode: [type: {:in, [:provider_managed, :asm_managed]}, required: true],
      transport_restart: [type: {:in, [:transient, :temporary]}, default: :temporary],
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

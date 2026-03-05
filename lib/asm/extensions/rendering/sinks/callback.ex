defmodule ASM.Extensions.Rendering.Sinks.Callback do
  @moduledoc """
  Sink that forwards events and rendered iodata to a callback function.

  Options:
  - `:callback` (required): `(event, iodata) -> term()`
  """

  @behaviour ASM.Extensions.Rendering.Sink

  alias ASM.Error

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :callback) do
      {:ok, callback} when is_function(callback, 2) ->
        {:ok, %{callback: callback}}

      {:ok, invalid} ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "callback sink :callback must be a 2-arity function, got: #{inspect(invalid)}"
         )}

      :error ->
        {:error, Error.new(:config_invalid, :config, "callback sink requires :callback option")}
    end
  end

  @impl true
  def write(_iodata, state), do: {:ok, state}

  @impl true
  def write_event(event, iodata, state) do
    _ = state.callback.(event, iodata)
    {:ok, state}
  rescue
    error ->
      {:error, Error.new(:unknown, :runtime, "callback sink write failed", cause: error), state}
  catch
    kind, reason ->
      {:error,
       Error.new(:unknown, :runtime, "callback sink write failed",
         cause: %{kind: kind, reason: reason}
       ), state}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def close(_state), do: :ok
end

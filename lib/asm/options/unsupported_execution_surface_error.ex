defmodule ASM.Options.UnsupportedExecutionSurfaceError do
  @moduledoc """
  Returned when preflight cannot normalize an execution surface.
  """

  defexception [:value, :reason, :message]

  @type t :: %__MODULE__{value: term(), reason: term(), message: String.t()}

  @impl true
  def exception(opts) do
    value = Keyword.get(opts, :value)
    reason = Keyword.get(opts, :reason)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        "execution_surface is invalid: #{inspect(reason)}"
      end)

    %__MODULE__{value: value, reason: reason, message: message}
  end
end

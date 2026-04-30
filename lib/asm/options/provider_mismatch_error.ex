defmodule ASM.Options.ProviderMismatchError do
  @moduledoc """
  Returned when an API receives conflicting positional and option providers.
  """

  defexception [:expected_provider, :actual_provider, :mode, :reason, :message]

  @type t :: %__MODULE__{
          expected_provider: atom() | nil,
          actual_provider: term(),
          mode: atom() | nil,
          reason: atom(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    expected_provider = Keyword.get(opts, :expected_provider)
    actual_provider = Keyword.get(opts, :actual_provider)
    mode = Keyword.get(opts, :mode)
    reason = Keyword.get(opts, :reason, :mismatch)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        case reason do
          :redundant_provider ->
            "provider is positional for ASM.query/3; remove redundant provider: #{inspect(actual_provider)} from opts"

          _ ->
            "provider option #{inspect(actual_provider)} does not match positional provider #{inspect(expected_provider)}"
        end
      end)

    %__MODULE__{
      expected_provider: expected_provider,
      actual_provider: actual_provider,
      mode: mode,
      reason: reason,
      message: message
    }
  end
end

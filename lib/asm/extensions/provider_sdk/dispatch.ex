defmodule ASM.Extensions.ProviderSDK.Dispatch do
  @moduledoc false

  @spec invoke_2(module(), atom(), term(), term()) :: term()
  def invoke_2(module, function, arg1, arg2)
      when is_atom(module) and is_atom(function) do
    # Capture the function dynamically so optional provider SDKs do not become
    # compile-time hard requirements for downstream consumers.
    Function.capture(module, function, 2).(arg1, arg2)
  end
end

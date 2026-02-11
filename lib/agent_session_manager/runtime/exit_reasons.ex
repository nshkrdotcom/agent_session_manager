defmodule AgentSessionManager.Runtime.ExitReasons do
  @moduledoc false

  @spec adapter_unavailable?(term()) :: boolean()
  def adapter_unavailable?(:noproc), do: true
  def adapter_unavailable?({:noproc, _}), do: true
  def adapter_unavailable?({:shutdown, {:noproc, _}}), do: true
  def adapter_unavailable?({:shutdown, _}), do: true
  def adapter_unavailable?(_), do: false
end

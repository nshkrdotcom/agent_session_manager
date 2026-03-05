defmodule ASM.Extensions.Persistence.Adapter do
  @moduledoc """
  Store adapter contract for persistence extension implementations.
  """

  alias ASM.{Error, Event}

  @callback append_event(pid(), Event.t()) :: :ok | {:error, Error.t()}
  @callback list_events(pid(), String.t()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  @callback reset_session(pid(), String.t()) :: :ok | {:error, Error.t()}
end

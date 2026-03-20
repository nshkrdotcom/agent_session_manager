defmodule ASM.ProviderBackend do
  @moduledoc """
  Runtime contract for provider backends.
  """

  @callback start_run(map()) :: {:ok, pid(), term()} | {:error, term()}
  @callback send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
  @callback end_input(pid()) :: :ok | {:error, term()}
  @callback interrupt(pid()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
  @callback subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
  @callback info(pid()) :: map()
end

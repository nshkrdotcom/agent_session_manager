defmodule ASM.ProviderBackend do
  @moduledoc """
  Runtime contract for provider backends.

  Both Phase 1 lanes satisfy this behaviour:

  - `ASM.ProviderBackend.Core`
  - `ASM.ProviderBackend.SDK`

  Lane selection is owned by `ASM.ProviderRegistry` and remains orthogonal to
  `execution_mode`.
  """

  @callback start_run(map()) :: {:ok, pid(), term()} | {:error, term()}
  @callback send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
  @callback end_input(pid()) :: :ok | {:error, term()}
  @callback interrupt(pid()) :: :ok | {:error, term()}
  @callback close(pid()) :: :ok
  @callback subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
  @callback info(pid()) :: map()
end

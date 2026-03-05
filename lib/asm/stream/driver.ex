defmodule ASM.Stream.Driver do
  @moduledoc """
  Driver contract for `ASM.Stream`.

  Drivers bridge run workers to provider backends. CLI and remote drivers are
  transport-backed; SDK drivers can emit run events directly without transport
  lease semantics.
  """

  alias ASM.Error
  alias ASM.Execution.Config

  @typedoc """
  Driver integration class.

  - `:transport` drivers are expected to attach a transport and let
    `ASM.Run.Server` handle transport lifecycle events.
  - `:sdk` drivers emit normalized `%ASM.Event{}` payloads directly.
  """
  @type kind :: :transport | :sdk

  @typedoc """
  Context passed to drivers on startup and shutdown.
  """
  @type context :: %{
          required(:run_id) => String.t(),
          required(:run_pid) => pid(),
          required(:session_id) => String.t(),
          required(:provider) => atom(),
          required(:prompt) => String.t(),
          required(:provider_opts) => keyword(),
          required(:driver_opts) => keyword(),
          required(:execution_config) => Config.t()
        }

  @callback kind() :: kind()
  @callback start(context()) :: {:ok, pid()} | {:error, Error.t() | term()}
  @callback stop(pid(), context()) :: :ok
end

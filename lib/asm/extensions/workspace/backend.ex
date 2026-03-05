defmodule ASM.Extensions.Workspace.Backend do
  @moduledoc """
  Behavior contract for workspace snapshot backends.
  """

  alias ASM.Error
  alias ASM.Extensions.Workspace.{Diff, Snapshot}

  @callback snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  @callback diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  @callback rollback(Snapshot.t(), keyword()) :: :ok | {:error, Error.t()}
end

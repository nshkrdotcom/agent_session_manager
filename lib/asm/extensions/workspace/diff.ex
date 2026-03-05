defmodule ASM.Extensions.Workspace.Diff do
  @moduledoc """
  Workspace diff result between two snapshots.
  """

  @enforce_keys [:backend, :from_snapshot_id, :to_snapshot_id]
  defstruct [
    :backend,
    :from_snapshot_id,
    :to_snapshot_id,
    added: [],
    modified: [],
    deleted: [],
    metadata: %{}
  ]

  @type backend_kind :: :git | :hash

  @type t :: %__MODULE__{
          backend: backend_kind(),
          from_snapshot_id: String.t(),
          to_snapshot_id: String.t(),
          added: [String.t()],
          modified: [String.t()],
          deleted: [String.t()],
          metadata: map()
        }

  @spec changed_count(t()) :: non_neg_integer()
  def changed_count(%__MODULE__{} = diff) do
    length(diff.added) + length(diff.modified) + length(diff.deleted)
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = diff), do: changed_count(diff) == 0

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = diff) do
    %{
      backend: diff.backend,
      added: length(diff.added),
      modified: length(diff.modified),
      deleted: length(diff.deleted),
      changed: changed_count(diff)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diff) do
    %{
      backend: diff.backend,
      from_snapshot_id: diff.from_snapshot_id,
      to_snapshot_id: diff.to_snapshot_id,
      added: diff.added,
      modified: diff.modified,
      deleted: diff.deleted,
      changed_count: changed_count(diff),
      summary: summary(diff),
      metadata: diff.metadata
    }
  end
end

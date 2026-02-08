defmodule AgentSessionManager.Workspace.Diff do
  @moduledoc """
  Represents a diff between two workspace snapshots.
  """

  @type backend :: :git | :hash

  @type t :: %__MODULE__{
          backend: backend(),
          from_ref: String.t() | nil,
          to_ref: String.t() | nil,
          files_changed: non_neg_integer(),
          insertions: non_neg_integer(),
          deletions: non_neg_integer(),
          changed_paths: [String.t()],
          patch: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:backend]
  defstruct [
    :backend,
    :from_ref,
    :to_ref,
    :patch,
    changed_paths: [],
    metadata: %{},
    files_changed: 0,
    insertions: 0,
    deletions: 0
  ]

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diff) do
    %{
      backend: diff.backend,
      from_ref: diff.from_ref,
      to_ref: diff.to_ref,
      files_changed: diff.files_changed,
      insertions: diff.insertions,
      deletions: diff.deletions,
      changed_paths: diff.changed_paths,
      patch: diff.patch,
      metadata: diff.metadata
    }
  end

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = diff) do
    %{
      files_changed: diff.files_changed,
      insertions: diff.insertions,
      deletions: diff.deletions,
      changed_paths: diff.changed_paths
    }
  end
end

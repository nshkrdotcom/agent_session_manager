defmodule AgentSessionManager.Workspace.Snapshot do
  @moduledoc """
  Represents a captured workspace state at a point in time.
  """

  @type backend :: :git | :hash

  @type t :: %__MODULE__{
          backend: backend(),
          path: String.t(),
          ref: String.t() | nil,
          label: atom() | nil,
          captured_at: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:backend, :path, :captured_at]
  defstruct [:backend, :path, :ref, :label, :captured_at, metadata: %{}]

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      backend: snapshot.backend,
      path: snapshot.path,
      ref: snapshot.ref,
      label: snapshot.label,
      captured_at: snapshot.captured_at,
      metadata: snapshot.metadata
    }
  end
end

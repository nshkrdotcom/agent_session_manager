defmodule ASM.Extensions.Workspace.Snapshot do
  @moduledoc """
  Immutable workspace snapshot descriptor.
  """

  @enforce_keys [:id, :backend, :root, :fingerprint, :captured_at]
  defstruct [:id, :backend, :root, :fingerprint, :captured_at, metadata: %{}]

  @type backend_kind :: :git | :hash

  @type t :: %__MODULE__{
          id: String.t(),
          backend: backend_kind(),
          root: String.t(),
          fingerprint: String.t(),
          captured_at: DateTime.t(),
          metadata: map()
        }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      id: snapshot.id,
      backend: snapshot.backend,
      root: snapshot.root,
      fingerprint: snapshot.fingerprint,
      captured_at: snapshot.captured_at,
      metadata: snapshot.metadata
    }
  end
end

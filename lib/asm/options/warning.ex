defmodule ASM.Options.Warning do
  @moduledoc """
  Structured compatibility warning returned by `ASM.Options.preflight/3`.
  """

  @enforce_keys [:key, :reason, :message]
  defstruct [:key, :reason, :message, :migration, :mode]

  @type t :: %__MODULE__{
          key: atom(),
          reason: atom(),
          message: String.t(),
          migration: String.t() | nil,
          mode: atom() | nil
        }
end

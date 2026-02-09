defmodule AgentSessionManager.PermissionMode do
  @moduledoc """
  Normalized permission modes for agent session execution.

  Each AI provider has its own mechanism for controlling tool permissions:

  - **Claude**: `--permission-mode` flag with modes like `bypassPermissions`
  - **Codex**: `--full-auto` and `--dangerously-bypass-approvals-and-sandbox` flags
  - **Amp**: `--dangerously-allow-all` flag

  This module defines a provider-agnostic set of permission modes that each
  adapter maps to its SDK's native semantics.

  ## Modes

  | Mode | Description |
  |---|---|
  | `:default` | Provider's default permission handling |
  | `:accept_edits` | Auto-accept file edit operations (Claude-specific; no-op on others) |
  | `:plan` | Plan mode — generate plan before executing (Claude-specific; no-op on others) |
  | `:full_auto` | Skip permission prompts, allow all tool calls |
  | `:dangerously_skip_permissions` | Bypass all approvals and sandboxing (most permissive) |
  """

  @type t :: :default | :accept_edits | :plan | :full_auto | :dangerously_skip_permissions

  @valid_modes [:default, :accept_edits, :plan, :full_auto, :dangerously_skip_permissions]
  @valid_strings Enum.map(@valid_modes, &Atom.to_string/1)

  @doc """
  Returns all valid permission modes.
  """
  @spec all() :: [t()]
  def all, do: @valid_modes

  @doc """
  Returns `true` if the given value is a valid permission mode atom.
  """
  @spec valid?(term()) :: boolean()
  def valid?(mode) when mode in @valid_modes, do: true
  def valid?(_), do: false

  @doc """
  Normalizes a permission mode value.

  Accepts atoms, strings, or `nil`. Returns `{:ok, mode}` for valid values
  or `{:error, reason}` for invalid ones. `nil` input returns `{:ok, nil}`.
  """
  @spec normalize(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}
  def normalize(mode) when mode in @valid_modes, do: {:ok, mode}

  def normalize(mode) when is_binary(mode) and mode in @valid_strings do
    {:ok, String.to_existing_atom(mode)}
  end

  def normalize(mode) when is_atom(mode) do
    {:error,
     "invalid permission mode: #{inspect(mode)}, expected one of #{inspect(@valid_modes)}"}
  end

  def normalize(mode) when is_binary(mode) do
    {:error,
     "invalid permission mode: #{inspect(mode)}, expected one of #{inspect(@valid_strings)}"}
  end

  def normalize(mode) do
    {:error, "invalid permission mode: #{inspect(mode)}, expected an atom or string"}
  end
end

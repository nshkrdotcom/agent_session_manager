defmodule ASM.EnvSnapshot do
  @moduledoc """
  Allowlist filter for the `config/runtime.exs` environment snapshot.

  ASM copies OS environment variables into Application config (backing
  `ASM.Env`) at boot. Copying the *whole* environment would spread every
  unrelated secret in the parent process into inspectable Application
  config (`Application.get_all_env/1`, `:observer`, crash dumps), so only
  the variables ASM reads are taken: the provider namespaces (which cover
  `ASM.RuntimeAuth`'s per-provider auth env keys) plus a small static set.
  """

  @static_vars ~w(ASM_PERMISSION_MODE PATH HOME MIX_ENV CI LIVE_MODE LIVE_TESTS)
  @prefixes ~w(ASM_ CLAUDE_ ANTHROPIC_ CODEX_ OPENAI_ AMP_ CURSOR_ ANTIGRAVITY_)

  @doc "Static (non-prefixed) variable names in the allowlist."
  @spec static_vars() :: [String.t()]
  def static_vars, do: @static_vars

  @doc "Variable-name prefixes admitted by the allowlist."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc "Filters an OS environment map down to the variables ASM reads."
  @spec take(%{optional(String.t()) => String.t()}) ::
          %{optional(String.t()) => String.t()}
  def take(os_env) when is_map(os_env) do
    Map.filter(os_env, fn {key, _value} -> allowed?(key) end)
  end

  @doc "Whether a variable name is admitted into the snapshot."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(key) when is_binary(key) do
    key in @static_vars or Enum.any?(@prefixes, &String.starts_with?(key, &1))
  end
end

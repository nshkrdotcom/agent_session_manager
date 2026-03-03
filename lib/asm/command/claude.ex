defmodule ASM.Command.Claude do
  @moduledoc """
  Builds Claude CLI command args from normalized ASM options.
  """

  alias ASM.{Command, Permission}
  alias ASM.Provider.Resolver

  @behaviour Command

  @required_flags ["--output-format", "stream-json", "--verbose", "--print"]

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, ASM.Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:claude, opts) do
      {:ok, command_spec, build_args(prompt, opts, Keyword.get(opts, :resume))}
    end
  end

  @spec build_args(String.t(), keyword(), String.t() | nil) :: [String.t()]
  def build_args(prompt, opts, resume_session_id \\ nil) do
    resume_args = if is_binary(resume_session_id), do: ["--resume", resume_session_id], else: []

    @required_flags ++ resume_args ++ to_cli_args(opts) ++ [prompt]
  end

  @spec to_cli_args(keyword()) :: [String.t()]
  def to_cli_args(opts) do
    permission_mode =
      opts
      |> provider_permission_mode()
      |> native_permission_to_flag()

    []
    |> maybe_add_pair("--model", Keyword.get(opts, :model))
    |> maybe_add_pair("--max-turns", Keyword.get(opts, :max_turns))
    |> maybe_add_pair("--append-system-prompt", Keyword.get(opts, :append_system_prompt))
    |> maybe_add_pair("--system-prompt", Keyword.get(opts, :system_prompt))
    |> maybe_add_pair("--permission-mode", permission_mode)
    |> maybe_add_flag("--thinking", Keyword.get(opts, :include_thinking, false))
  end

  defp maybe_add_pair(args, _flag, nil), do: args
  defp maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]

  defp provider_permission_mode(opts) do
    case Keyword.get(opts, :provider_permission_mode) do
      nil ->
        Permission.normalize!(:claude, Keyword.get(opts, :permission_mode, :default)).native

      value ->
        value
    end
  end

  defp native_permission_to_flag(:default), do: "default"
  defp native_permission_to_flag(:accept_edits), do: "acceptEdits"
  defp native_permission_to_flag(:bypass_permissions), do: "bypassPermissions"
  defp native_permission_to_flag(:delegate), do: "delegate"
  defp native_permission_to_flag(:dont_ask), do: "dontAsk"
  defp native_permission_to_flag(:plan), do: "plan"
  defp native_permission_to_flag(other), do: to_string(other)
end

defmodule ASM.Command.Amp do
  @moduledoc """
  Builds Amp CLI command args from normalized ASM options.
  """

  alias ASM.{Command, Error, Permission}
  alias ASM.Provider.Resolver

  @behaviour Command

  @required_flags ["run", "--output", "jsonl"]

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:amp, opts),
         {:ok, args} <- build_args_safe(prompt, opts) do
      {:ok, command_spec, args}
    end
  end

  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) do
    @required_flags ++ option_flags(opts) ++ [prompt]
  end

  @spec option_flags(keyword()) :: [String.t()]
  def option_flags(opts) do
    native_mode =
      case Keyword.get(opts, :provider_permission_mode) do
        nil ->
          Permission.normalize!(:amp, Keyword.get(opts, :permission_mode, :default)).native

        mode ->
          mode
      end

    []
    |> maybe_add_pair("--model", Keyword.get(opts, :model))
    |> maybe_add_pair("--mode", Keyword.get(opts, :mode))
    |> maybe_add_pair("--max-turns", Keyword.get(opts, :max_turns))
    |> maybe_add_pair("--system-prompt", Keyword.get(opts, :system_prompt))
    |> maybe_add_json_pair("--permissions-json", Keyword.get(opts, :permissions))
    |> maybe_add_json_pair("--mcp-config-json", Keyword.get(opts, :mcp_config))
    |> maybe_add_tools(Keyword.get(opts, :tools, []))
    |> maybe_add_flag("--thinking", Keyword.get(opts, :include_thinking, false))
    |> add_permission_flags(native_mode)
  end

  defp build_args_safe(prompt, opts) do
    {:ok, build_args(prompt, opts)}
  rescue
    error ->
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "Amp command option encoding failed: #{Exception.message(error)}",
         cause: error
       )}
  end

  defp maybe_add_pair(args, _flag, nil), do: args
  defp maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_json_pair(args, _flag, nil), do: args

  defp maybe_add_json_pair(args, flag, value) when is_map(value) do
    args ++ [flag, Jason.encode!(value)]
  end

  defp maybe_add_json_pair(args, _flag, _other), do: args

  defp maybe_add_tools(args, tools) when is_list(tools) do
    Enum.reduce(tools, args, fn
      tool, acc when is_binary(tool) and tool != "" -> acc ++ ["--tool", tool]
      _tool, acc -> acc
    end)
  end

  defp maybe_add_tools(args, _tools), do: args

  defp maybe_add_flag(args, _flag, false), do: args
  defp maybe_add_flag(args, flag, true), do: args ++ [flag]

  defp add_permission_flags(args, :default), do: args
  defp add_permission_flags(args, :auto), do: args ++ ["--permission-mode", "auto"]
  defp add_permission_flags(args, :plan), do: args ++ ["--permission-mode", "plan"]
  defp add_permission_flags(args, :dangerously_allow_all), do: args ++ ["--dangerously-allow-all"]

  defp add_permission_flags(args, mode) when is_atom(mode) do
    args ++ ["--permission-mode", Atom.to_string(mode)]
  end

  defp add_permission_flags(args, mode) when is_binary(mode) do
    args ++ ["--permission-mode", mode]
  end

  defp add_permission_flags(args, _other), do: args
end

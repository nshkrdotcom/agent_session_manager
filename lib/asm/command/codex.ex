defmodule ASM.Command.Codex do
  @moduledoc """
  Builds Codex exec command args from normalized ASM options.
  """

  alias ASM.{Command, Permission}
  alias ASM.Provider.Resolver

  @behaviour Command

  @required_flags ["exec", "--json"]

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, ASM.Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:codex_exec, opts) do
      {:ok, command_spec, build_args(prompt, opts)}
    end
  end

  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) do
    @required_flags ++
      option_flags(opts) ++
      [prompt]
  end

  @spec option_flags(keyword()) :: [String.t()]
  def option_flags(opts) do
    permission_flags = permission_flags(opts)

    []
    |> maybe_add_pair("--model", Keyword.get(opts, :model))
    |> maybe_add_pair("--reasoning-effort", Keyword.get(opts, :reasoning_effort))
    |> maybe_add_output_schema(Keyword.get(opts, :output_schema))
    |> Kernel.++(permission_flags)
  end

  defp permission_flags(opts) do
    native_mode =
      case Keyword.get(opts, :provider_permission_mode) do
        nil ->
          Permission.normalize!(:codex_exec, Keyword.get(opts, :permission_mode, :default)).native

        mode ->
          mode
      end

    case native_mode do
      :default -> []
      :auto_edit -> ["--full-auto"]
      :yolo -> ["--dangerously-bypass-approvals-and-sandbox"]
      :plan -> ["--plan"]
      _ -> []
    end
  end

  defp maybe_add_pair(args, _flag, nil), do: args
  defp maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_output_schema(args, nil), do: args

  defp maybe_add_output_schema(args, schema) when is_map(schema) do
    args ++ ["--output-schema", Jason.encode!(schema)]
  end

  defp maybe_add_output_schema(args, _other), do: args
end

defmodule ASM.Command.Codex do
  @moduledoc """
  Builds Codex exec command args from normalized ASM options.
  """

  alias ASM.{Command, Permission}
  alias ASM.Provider.Resolver

  @behaviour Command

  @required_flags ["exec", "--json"]
  @supports_reasoning_opt :supports_reasoning_effort?
  @supports_plan_opt :supports_plan_mode?

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, ASM.Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:codex_exec, opts) do
      opts = Keyword.merge(opts, codex_capabilities(command_spec, opts))
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
    |> maybe_add_reasoning_effort(
      Keyword.get(opts, :reasoning_effort),
      Keyword.get(opts, @supports_reasoning_opt, false)
    )
    |> maybe_add_output_schema(Keyword.get(opts, :output_schema))
    |> Kernel.++(permission_flags)
  end

  defp permission_flags(opts) do
    supports_plan = Keyword.get(opts, @supports_plan_opt, false)

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
      :plan when supports_plan -> ["--plan"]
      :plan -> []
      _ -> []
    end
  end

  defp maybe_add_pair(args, _flag, nil), do: args
  defp maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_reasoning_effort(args, value, true),
    do: maybe_add_pair(args, "--reasoning-effort", value)

  defp maybe_add_reasoning_effort(args, _value, false), do: args

  defp maybe_add_output_schema(args, nil), do: args

  defp maybe_add_output_schema(args, schema) when is_map(schema) do
    args ++ ["--output-schema", Jason.encode!(schema)]
  end

  defp maybe_add_output_schema(args, _other), do: args

  defp codex_capabilities(command_spec, opts) do
    if probe_capabilities?(opts) do
      [
        {@supports_reasoning_opt, supports_cli_flag?(command_spec, "--reasoning-effort", opts)},
        {@supports_plan_opt, supports_cli_flag?(command_spec, "--plan", opts)}
      ]
    else
      []
    end
  end

  defp probe_capabilities?(opts) do
    not is_nil(Keyword.get(opts, :reasoning_effort)) or requested_plan_mode?(opts)
  end

  defp requested_plan_mode?(opts) do
    case Keyword.get(opts, :provider_permission_mode) do
      :plan ->
        true

      nil ->
        Permission.normalize!(:codex_exec, Keyword.get(opts, :permission_mode, :default)).native ==
          :plan

      _ ->
        false
    end
  end

  defp supports_cli_flag?(command_spec, flag, opts) do
    system_cmd = Keyword.get(opts, :system_cmd, &default_system_cmd/2)
    help_args = Resolver.command_args(command_spec, ["exec", "--help"])

    case system_cmd.(command_spec.program, help_args) do
      {output, 0} when is_binary(output) -> String.contains?(output, flag)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp default_system_cmd(program, args) do
    System.cmd(program, args, stderr_to_stdout: true)
  end
end

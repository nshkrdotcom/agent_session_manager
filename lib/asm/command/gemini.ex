defmodule ASM.Command.Gemini do
  @moduledoc """
  Builds Gemini CLI command args from normalized ASM options.
  """

  alias ASM.{Command, Permission}
  alias ASM.Provider.Resolver

  @behaviour Command

  @impl true
  @spec build(String.t(), keyword()) ::
          {:ok, Resolver.CommandSpec.t(), [String.t()]} | {:error, ASM.Error.t()}
  def build(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, command_spec} <- Resolver.resolve(:gemini, opts) do
      {:ok, command_spec, build_args(prompt, opts)}
    end
  end

  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) do
    output_format = Keyword.get(opts, :output_format, "stream-json")

    ["--prompt", prompt, "--output-format", output_format] ++ option_flags(opts)
  end

  @spec option_flags(keyword()) :: [String.t()]
  def option_flags(opts) do
    native_mode =
      case Keyword.get(opts, :provider_permission_mode) do
        nil ->
          Permission.normalize!(:gemini, Keyword.get(opts, :permission_mode, :default)).native

        mode ->
          mode
      end

    []
    |> maybe_add_pair("--model", Keyword.get(opts, :model))
    |> maybe_add_sandbox(Keyword.get(opts, :sandbox, false))
    |> maybe_add_extensions(Keyword.get(opts, :extensions, []))
    |> add_permission_flags(native_mode)
  end

  defp maybe_add_pair(args, _flag, nil), do: args
  defp maybe_add_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp maybe_add_sandbox(args, true), do: args ++ ["--sandbox"]
  defp maybe_add_sandbox(args, _), do: args

  defp maybe_add_extensions(args, [_ | _] = extensions) do
    args ++ ["--extensions", Enum.join(extensions, ",")]
  end

  defp maybe_add_extensions(args, _), do: args

  defp add_permission_flags(args, :default), do: args
  defp add_permission_flags(args, :auto_edit), do: args ++ ["--approval-mode", "auto_edit"]
  defp add_permission_flags(args, :plan), do: args ++ ["--approval-mode", "plan"]
  defp add_permission_flags(args, :yolo), do: args ++ ["--yolo"]
  defp add_permission_flags(args, _), do: args
end

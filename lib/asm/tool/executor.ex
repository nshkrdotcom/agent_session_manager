defmodule ASM.Tool.Executor do
  @moduledoc """
  Synchronous tool execution adapter used by `ASM.Run.Server`.
  """

  alias ASM.Message
  alias ASM.Run

  @spec execute(Message.ToolUse.t(), Run.State.t()) :: Message.ToolResult.t()
  def execute(%Message.ToolUse{} = tool_use, %Run.State{} = state) do
    context = %{
      run_id: state.run_id,
      session_id: state.session_id,
      provider: state.provider
    }

    case resolve_tool(state.tools, tool_use.tool_name) do
      {:ok, tool_impl} ->
        invoke_tool(tool_impl, tool_use.input, context, tool_use.tool_id)

      :error ->
        %Message.ToolResult{
          tool_id: tool_use.tool_id,
          content: "tool_not_found: #{tool_use.tool_name}",
          is_error: true
        }
    end
  end

  defp resolve_tool(tools, tool_name) when is_map(tools) do
    case Map.fetch(tools, tool_name) do
      {:ok, impl} -> {:ok, impl}
      :error -> :error
    end
  end

  defp invoke_tool(tool_impl, input, context, tool_id) when is_function(tool_impl, 2) do
    normalize_tool_result(tool_impl.(input, context), tool_id)
  end

  defp invoke_tool(tool_impl, input, context, tool_id) when is_atom(tool_impl) do
    if Code.ensure_loaded?(tool_impl) and function_exported?(tool_impl, :call, 2) do
      normalize_tool_result(tool_impl.call(input, context), tool_id)
    else
      %Message.ToolResult{tool_id: tool_id, content: "invalid_tool_module", is_error: true}
    end
  end

  defp invoke_tool({module, module_opts}, input, context, tool_id)
       when is_atom(module) and is_list(module_opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      merged_context = Map.put(context, :tool_opts, module_opts)
      normalize_tool_result(module.call(input, merged_context), tool_id)
    else
      %Message.ToolResult{tool_id: tool_id, content: "invalid_tool_module", is_error: true}
    end
  end

  defp invoke_tool(_other, _input, _context, tool_id) do
    %Message.ToolResult{tool_id: tool_id, content: "invalid_tool", is_error: true}
  end

  defp normalize_tool_result({:ok, content}, tool_id) do
    %Message.ToolResult{tool_id: tool_id, content: content, is_error: false}
  end

  defp normalize_tool_result({:error, reason}, tool_id) do
    %Message.ToolResult{tool_id: tool_id, content: inspect(reason), is_error: true}
  end

  defp normalize_tool_result(other, tool_id) do
    %Message.ToolResult{tool_id: tool_id, content: other, is_error: false}
  end
end

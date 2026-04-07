defmodule ASM.Tool.MCP do
  @moduledoc """
  Optional MCP tool bridge placeholder.

  v1 runtime keeps MCP integration optional; this module returns an explicit
  not-configured error unless a custom router function is provided in context.
  """

  @behaviour ASM.Tool

  @impl true
  @spec call(map(), map()) :: {:ok, term()} | {:error, term()}
  def call(input, context) when is_map(input) and is_map(context) do
    case Map.get(context, :mcp_router) do
      router when is_function(router, 2) -> router.(input, context)
      _ -> {:error, :mcp_not_configured}
    end
  end
end

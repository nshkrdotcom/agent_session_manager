defmodule ASM.Pipeline do
  @moduledoc """
  Synchronous event pipeline with optional event injection.
  """

  alias ASM.Error

  @type plug_ref ::
          module() | (ASM.Event.t(), map() -> {:ok, ASM.Event.t(), map()}) | {module(), keyword()}

  @spec run(ASM.Event.t(), [plug_ref()], map()) ::
          {:ok, [ASM.Event.t()], map()} | {:error, Error.t(), map()}
  def run(event, plugs, ctx \\ %{}) when is_list(plugs) and is_map(ctx) do
    Enum.reduce_while(plugs, {:ok, event, [], ctx}, fn plug, {:ok, current, injected, plug_ctx} ->
      case call_plug(plug, current, plug_ctx) do
        {:ok, next_event, next_ctx} ->
          {:cont, {:ok, next_event, injected, next_ctx}}

        {:ok, next_event, plug_injected, next_ctx} ->
          {:cont, {:ok, next_event, injected ++ List.wrap(plug_injected), next_ctx}}

        {:halt, next_event, next_ctx} ->
          {:halt, {:ok, [next_event] ++ injected, next_ctx}}

        {:halt, next_event, plug_injected, next_ctx} ->
          {:halt, {:ok, [next_event] ++ injected ++ List.wrap(plug_injected), next_ctx}}

        {:error, %Error{} = error, next_ctx} ->
          {:halt, {:error, error, next_ctx}}

        {:error, reason, next_ctx} ->
          error =
            Error.new(:guardrail_blocked, :guardrail, "Pipeline plug rejected event",
              cause: reason
            )

          {:halt, {:error, error, next_ctx}}
      end
    end)
    |> normalize_result()
  end

  defp normalize_result({:ok, event, injected, ctx}) do
    {:ok, [event] ++ injected, ctx}
  end

  defp normalize_result(other), do: other

  defp call_plug({module, opts}, event, ctx) when is_atom(module) and is_list(opts) do
    module.call(event, ctx, opts)
  end

  defp call_plug(module, event, ctx) when is_atom(module) do
    module.call(event, ctx, [])
  end

  defp call_plug(fun, event, ctx) when is_function(fun, 2) do
    case fun.(event, ctx) do
      {:ok, %ASM.Event{} = next_event, next_ctx} -> {:ok, next_event, next_ctx}
      {:error, reason} -> {:error, reason, ctx}
      other -> {:error, {:invalid_pipeline_fun_return, other}, ctx}
    end
  end
end

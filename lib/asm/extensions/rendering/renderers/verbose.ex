defmodule ASM.Extensions.Rendering.Renderers.Verbose do
  @moduledoc """
  Verbose line-by-line renderer for `%ASM.Event{}` streams.
  """

  @behaviour ASM.Extensions.Rendering.Renderer

  alias ASM.{Content, Control, Event, Message}

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @dim "\e[2m"
  @nc "\e[0m"

  @preview_limit 240

  @impl true
  def init(opts) do
    {:ok,
     %{
       color: Keyword.get(opts, :color, true),
       in_text: false,
       event_count: 0,
       tool_count: 0
     }}
  end

  @impl true
  def render_event(%Event{} = event, state) do
    state = %{state | event_count: state.event_count + 1}
    {iodata, state} = render(event, state)
    {:ok, iodata, state}
  end

  @impl true
  def finish(state) do
    closing = if state.in_text, do: "\n", else: ""
    summary = dim("--- #{state.event_count} events, #{state.tool_count} tools ---\n", state)
    {:ok, [closing, summary], state}
  end

  defp render(%Event{kind: :run_started, run_id: run_id, session_id: session_id}, state) do
    line = [
      tag("[run_started]", @blue, state),
      " run_id=",
      run_id,
      " session_id=",
      session_id,
      "\n"
    ]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(
         %Event{
           kind: :assistant_delta,
           payload: %Message.Partial{content_type: :text, delta: delta}
         },
         state
       )
       when is_binary(delta) do
    {delta, %{state | in_text: true}}
  end

  defp render(
         %Event{kind: :assistant_message, payload: %Message.Assistant{content: blocks}},
         state
       ) do
    text = blocks |> text_blocks_to_string() |> truncate(@preview_limit)
    line = [tag("[assistant_message]", @blue, state), " ", text, "\n"]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(%Event{kind: :tool_use, payload: %Message.ToolUse{} = payload}, state) do
    line =
      [
        tag("[tool_use]", @green, state),
        " name=",
        payload.tool_name,
        " id=",
        payload.tool_id,
        tool_input_suffix(payload.input),
        "\n"
      ]

    {break_line_if_needed(state), line,
     %{state | in_text: false, tool_count: state.tool_count + 1}}
    |> merge_render_result()
  end

  defp render(%Event{kind: :tool_result, payload: %Message.ToolResult{} = payload}, state) do
    line =
      [
        tag("[tool_result]", @green, state),
        " id=",
        payload.tool_id,
        tool_result_suffix(payload.content, payload.is_error),
        "\n"
      ]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(%Event{kind: :result, payload: %Message.Result{} = payload}, state) do
    line =
      [
        tag("[result]", @blue, state),
        " stop_reason=",
        normalize_stop_reason(payload.stop_reason),
        usage_suffix(payload.usage),
        duration_suffix(payload.duration_ms),
        "\n"
      ]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(%Event{kind: :run_completed, payload: %Control.RunLifecycle{} = payload}, state) do
    line = [
      tag("[run_completed]", @blue, state),
      " status=",
      Atom.to_string(payload.status),
      "\n"
    ]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(%Event{kind: :error, payload: %Message.Error{} = payload}, state) do
    line =
      [
        tag("[error]", @red, state),
        " kind=",
        Atom.to_string(payload.kind),
        " severity=",
        Atom.to_string(payload.severity),
        " message=",
        truncate(payload.message, @preview_limit),
        "\n"
      ]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp render(%Event{kind: kind}, state) do
    line = [dim("[event]", state), " kind=", Atom.to_string(kind), "\n"]

    {break_line_if_needed(state), line, %{state | in_text: false}}
    |> merge_render_result()
  end

  defp merge_render_result({break, line, state}), do: {[break, line], state}

  defp break_line_if_needed(%{in_text: true}), do: "\n"
  defp break_line_if_needed(_state), do: ""

  defp tag(text, color, %{color: true}), do: color <> text <> @nc
  defp tag(text, _color, _state), do: text

  defp dim(text, %{color: true}), do: @dim <> text <> @nc
  defp dim(text, _state), do: text

  defp tool_input_suffix(nil), do: ""
  defp tool_input_suffix(%{} = input) when map_size(input) == 0, do: ""
  defp tool_input_suffix(input), do: " input=" <> truncate(inspect(input), @preview_limit)

  defp tool_result_suffix(nil, _is_error), do: ""

  defp tool_result_suffix(content, is_error) do
    status = if is_error, do: " error=true", else: ""
    status <> " content=" <> truncate(inspect(content), @preview_limit)
  end

  defp usage_suffix(usage) when is_map(usage) do
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0
    output_tokens = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
    " tokens=#{input_tokens}/#{output_tokens}"
  end

  defp usage_suffix(_other), do: ""

  defp duration_suffix(nil), do: ""
  defp duration_suffix(duration_ms), do: " duration_ms=#{duration_ms}"

  defp normalize_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_stop_reason(reason) when is_binary(reason), do: reason
  defp normalize_stop_reason(other), do: inspect(other)

  defp text_blocks_to_string(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
  end

  defp text_blocks_to_string(_other), do: ""

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp truncate(other, limit), do: truncate(inspect(other), limit)
end

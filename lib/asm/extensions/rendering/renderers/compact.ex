defmodule ASM.Extensions.Rendering.Renderers.Compact do
  @moduledoc """
  Compact token renderer for `%ASM.Event{}` streams.
  """

  @behaviour ASM.Extensions.Rendering.Renderer

  alias ASM.{Content, Control, Event, Message}

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @magenta "\e[0;35m"
  @dim "\e[2m"
  @nc "\e[0m"

  @preview_limit 240

  @impl true
  def init(opts) do
    {:ok,
     %{
       color: Keyword.get(opts, :color, true),
       event_count: 0,
       tool_count: 0,
       streaming_text?: false,
       line_open?: false
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
    closing = if state.line_open?, do: "\n", else: ""

    summary =
      [
        "\n",
        dim("#{state.event_count} events, #{state.tool_count} tools\n", state)
      ]

    {:ok, [closing, summary], state}
  end

  defp render(%Event{kind: :run_started}, state) do
    start_token(state, [colorize("r+", @blue, state), provider_suffix(state, :run_started)])
  end

  defp render(
         %Event{
           kind: :assistant_delta,
           payload: %Message.Partial{content_type: :text, delta: delta}
         },
         state
       )
       when is_binary(delta) do
    if state.streaming_text? do
      {delta, %{state | line_open?: true}}
    else
      prefix = [maybe_space(state), colorize(">>", @magenta, state), " "]
      {[prefix, delta], %{state | streaming_text?: true, line_open?: true}}
    end
  end

  defp render(
         %Event{kind: :assistant_message, payload: %Message.Assistant{content: content}},
         state
       ) do
    text = content |> extract_text_blocks() |> Enum.join() |> truncate(@preview_limit)
    start_token(state, [colorize("msg", @blue, state), " ", dim(text, state)])
  end

  defp render(%Event{kind: :tool_use, payload: %Message.ToolUse{} = payload}, state) do
    token = [colorize("t+#{payload.tool_name}", @green, state), tool_input_suffix(payload, state)]
    {iodata, state} = start_token(state, token)
    {iodata, %{state | tool_count: state.tool_count + 1}}
  end

  defp render(%Event{kind: :tool_result, payload: %Message.ToolResult{} = payload}, state) do
    token = [
      colorize("t-#{payload.tool_id}", @green, state),
      tool_result_suffix(payload, state)
    ]

    start_token(state, token)
  end

  defp render(%Event{kind: :result, payload: %Message.Result{} = payload}, state) do
    reason = payload.stop_reason |> normalize_stop_reason() |> short_reason()

    token =
      if reason == "" do
        colorize("r-", @blue, state)
      else
        colorize("r-:#{reason}", @blue, state)
      end

    usage_suffix = result_usage_suffix(payload.usage, state)
    start_token(state, [token, usage_suffix])
  end

  defp render(%Event{kind: :run_completed, payload: %Control.RunLifecycle{status: status}}, state) do
    start_token(state, colorize("rc:#{status}", @blue, state))
  end

  defp render(%Event{kind: :error, payload: %Message.Error{} = payload}, state) do
    token = [
      colorize("!", @red, state),
      " ",
      dim(truncate(payload.message, @preview_limit), state)
    ]

    start_token(state, token)
  end

  defp render(%Event{kind: kind}, state) do
    start_token(state, [dim("?", state), dim(Atom.to_string(kind), state)])
  end

  defp start_token(state, token) do
    prefix = [stream_closing(state), maybe_space(state)]
    {[prefix, token], %{state | streaming_text?: false, line_open?: true}}
  end

  defp stream_closing(%{streaming_text?: true}), do: "\n"
  defp stream_closing(_state), do: ""

  defp maybe_space(%{line_open?: true, streaming_text?: false}), do: " "
  defp maybe_space(%{line_open?: true, streaming_text?: true}), do: ""
  defp maybe_space(_state), do: ""

  defp colorize(text, color, %{color: true}), do: color <> text <> @nc
  defp colorize(text, _color, _state), do: text

  defp dim(text, %{color: true}), do: @dim <> text <> @nc
  defp dim(text, _state), do: text

  defp provider_suffix(_state, _kind), do: ""

  defp tool_input_suffix(%Message.ToolUse{input: input}, _state) when input in [%{}, nil], do: ""

  defp tool_input_suffix(%Message.ToolUse{input: input}, state) do
    [" ", dim(truncate(inspect(input), @preview_limit), state)]
  end

  defp tool_result_suffix(%Message.ToolResult{content: nil}, _state), do: ""

  defp tool_result_suffix(%Message.ToolResult{content: content}, state) do
    [" ", dim(truncate(inspect(content), @preview_limit), state)]
  end

  defp result_usage_suffix(usage, state) when is_map(usage) do
    input_tokens = Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens")
    output_tokens = Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens")

    case {input_tokens, output_tokens} do
      {nil, nil} -> ""
      {in_t, out_t} -> [" ", dim("tk:#{default_zero(in_t)}/#{default_zero(out_t)}", state)]
    end
  end

  defp result_usage_suffix(_usage, _state), do: ""

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value

  defp normalize_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_stop_reason(reason) when is_binary(reason), do: reason
  defp normalize_stop_reason(_other), do: ""

  defp short_reason("end_turn"), do: "end"
  defp short_reason("tool_use"), do: "tool"
  defp short_reason(reason), do: reason

  defp extract_text_blocks(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
  end

  defp extract_text_blocks(_other), do: []

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

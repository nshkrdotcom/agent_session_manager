defmodule AgentSessionManager.Rendering.Renderers.CompactRenderer do
  @moduledoc """
  Compact single-line token renderer for agent session events.

  Renders canonical adapter events (`:run_started`, `:message_streamed`,
  `:tool_call_started`, etc.) into compact colored tokens suitable for
  terminal display. Text and tool input are streamed inline.

  ## Token Legend

      r+ = run started    r- = run completed
      t+ = tool started   t- = tool completed
      >> = text stream     tk = token usage
      !  = error           ?  = unknown event

  ## Options

    * `:color` — Enable ANSI color output. Default `true`.
  """

  @behaviour AgentSessionManager.Rendering.Renderer

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @magenta "\e[0;35m"
  @dim "\e[2m"
  @nc "\e[0m"

  @tool_preview_limit 120
  @result_preview_limit 2000

  @type state :: map()

  @impl true
  def init(opts) do
    {:ok,
     %{
       color: Keyword.get(opts, :color, true),
       streaming: nil,
       line_open: false,
       in_text: false,
       event_count: 0,
       tool_count: 0,
       current_tool: nil,
       current_tool_id: nil
     }}
  end

  @impl true
  def render_event(event, state) do
    state = %{state | event_count: state.event_count + 1}
    {iodata, state} = render(event, state)
    {:ok, iodata, state}
  end

  @impl true
  def finish(state) do
    {closing, state} = end_stream(state)
    summary = summary_line(state)
    {:ok, [closing, summary], state}
  end

  # -- Event handlers --

  defp render(%{type: :run_started, data: data}, state) do
    {closing, state} = end_stream(state)
    model = short_model(data[:model])
    token = emit_token(state, [colorize("r+", @blue, state), model_label(model, state)])
    {[closing, token], %{state | line_open: true}}
  end

  defp render(%{type: :message_streamed, data: data}, state) do
    text = data[:delta] || data[:content] || ""

    if state.streaming == :text do
      # Continue streaming — just the raw text
      {text, %{state | line_open: true, in_text: true}}
    else
      # Enter text streaming
      {closing, state} = end_stream(state)
      prefix = space_if_open(state) <> colorize(">>", @magenta, state) <> " "
      {[closing, prefix, text], %{state | streaming: :text, line_open: true, in_text: true}}
    end
  end

  defp render(%{type: :tool_call_started, data: data}, state) do
    {closing, state} = end_stream(state)
    name = data[:tool_name] || "unknown"
    token = emit_token(state, colorize("t+#{name}", @green, state))

    state = %{
      state
      | tool_count: state.tool_count + 1,
        current_tool: name,
        current_tool_id: data[:tool_call_id] || data[:tool_use_id],
        line_open: true
    }

    {[closing, token], state}
  end

  defp render(%{type: :tool_call_completed, data: data}, state) do
    {closing, state} = end_stream(state)
    name = data[:tool_name] || "unknown"
    token = emit_token(state, colorize("t-#{name}", @green, state))

    result_token =
      case data[:tool_output] do
        nil ->
          []

        "" ->
          []

        output ->
          [
            " ",
            colorize("tr:", @green, state),
            dim(format_value(output, @result_preview_limit), state)
          ]
      end

    state = %{state | current_tool: nil, current_tool_id: nil}
    {[closing, token | result_token], %{state | line_open: true}}
  end

  defp render(%{type: :token_usage_updated, data: data}, state) do
    {closing, state} = end_stream(state)
    input_t = data[:input_tokens] || 0
    output_t = data[:output_tokens] || 0
    token = emit_token(state, dim("tk:#{input_t}/#{output_t}", state))
    {[closing, token], %{state | line_open: true}}
  end

  defp render(%{type: :message_received, data: data}, state) do
    {closing, state} = end_stream(state)
    content = data[:content] || ""
    preview = truncate(content, @tool_preview_limit)
    token = emit_token(state, [colorize("msg", @blue, state), " ", dim(preview, state)])
    {[closing, token], %{state | in_text: false, line_open: true}}
  end

  defp render(%{type: :run_completed, data: data}, state) do
    {closing, state} = end_stream(state)
    reason = short_reason(data[:stop_reason])
    label = if reason == "", do: "r-", else: "r-:#{reason}"
    token = emit_token(state, colorize(label, @blue, state))
    {[closing, token], %{state | in_text: false, line_open: true}}
  end

  defp render(%{type: :run_failed, data: data}, state) do
    {closing, state} = end_stream(state)
    msg = data[:error_message] || "unknown error"

    token =
      emit_token(state, [
        colorize("!", @red, state),
        " ",
        dim(truncate(msg, @tool_preview_limit), state)
      ])

    {[closing, token], %{state | line_open: true}}
  end

  defp render(%{type: :run_cancelled}, state) do
    {closing, state} = end_stream(state)
    token = emit_token(state, [colorize("!", @red, state), " ", dim("cancelled", state)])
    {[closing, token], %{state | line_open: true}}
  end

  defp render(%{type: :error_occurred, data: data}, state) do
    {closing, state} = end_stream(state)
    msg = data[:error_message] || "unknown error"

    token =
      emit_token(state, [
        colorize("!", @red, state),
        " ",
        dim(truncate(msg, @tool_preview_limit), state)
      ])

    {[closing, token], %{state | line_open: true}}
  end

  # Catch-all for unknown events
  defp render(event, state) do
    {closing, state} = end_stream(state)
    preview = truncate(inspect(event.type), @tool_preview_limit)
    token = emit_token(state, [dim("?", state), dim(preview, state)])
    {[closing, token], %{state | line_open: true}}
  end

  # -- Streaming helpers --

  defp end_stream(%{streaming: nil} = state), do: {[], state}

  defp end_stream(state) do
    closing = if state.line_open, do: "\n", else: []
    {closing, %{state | streaming: nil, line_open: false}}
  end

  defp emit_token(state, content) do
    prefix = space_if_open(state)
    [prefix | List.wrap(content)]
  end

  defp space_if_open(%{line_open: true}), do: " "
  defp space_if_open(_), do: ""

  # -- Formatting helpers --

  defp colorize(text, color, %{color: true}), do: color <> text <> @nc
  defp colorize(text, _color, _state), do: text

  defp dim(text, %{color: true}), do: @dim <> text <> @nc
  defp dim(text, _state), do: text

  defp model_label("", _state), do: []
  defp model_label(model, state), do: [" ", colorize(model, @magenta, state)]

  defp short_model(nil), do: ""
  defp short_model(model) when is_atom(model), do: short_model(Atom.to_string(model))

  defp short_model(model) when is_binary(model) do
    model
    |> String.replace_prefix("claude-", "")
    |> String.replace_prefix("anthropic.", "")
    |> String.split("-", trim: true)
    |> Enum.take(3)
    |> Enum.join("-")
  end

  defp short_reason(nil), do: ""
  defp short_reason(reason) when is_atom(reason), do: short_reason(Atom.to_string(reason))

  defp short_reason(reason) when is_binary(reason) do
    case String.downcase(reason) do
      "tool_use" -> "tool"
      "end_turn" -> "end"
      other -> other
    end
  end

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp truncate(value, limit), do: truncate(inspect(value), limit)

  defp format_value(value, limit) when is_binary(value), do: truncate(value, limit)

  defp format_value(value, limit) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> truncate(json, limit)
      _ -> truncate(inspect(value), limit)
    end
  end

  defp format_value(value, limit), do: truncate(inspect(value), limit)

  defp summary_line(state) do
    text = "#{state.event_count} events, #{state.tool_count} tools\n"
    ["\n", dim(text, state)]
  end
end

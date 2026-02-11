defmodule AgentSessionManager.Rendering.Renderers.VerboseRenderer do
  @moduledoc """
  Verbose line-by-line renderer for agent session events.

  Renders canonical adapter events into structured bracketed lines suitable
  for log files and detailed terminal output. Each event gets a full line
  with labeled fields.

  ## Format

      [run_started] model=claude-sonnet-4-5-20250929 session_id=ses_123
      Hello world
      [tool_call_started] name=Read id=tu_001 input={"path":"/foo.ex"}
      [tool_call_completed] name=Read output=defmodule Foo...
      [run_completed] stop_reason=end_turn tokens=100/50

  ## Options

    * `:color` — Enable ANSI color output. Default `true`.
  """

  @behaviour AgentSessionManager.Rendering.Renderer

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @dim "\e[2m"
  @nc "\e[0m"

  @preview_limit 120
  @result_limit 2000

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
  def render_event(event, state) do
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

  # -- Event handlers --

  defp render(%{type: :run_started, data: data} = event, state) do
    {break, state} = maybe_break_line(state)
    model = data[:model] || "unknown"
    session_id = event[:session_id] || data[:session_id] || ""

    tag = colorize("[run_started]", @blue, state)
    line = "#{tag} model=#{model} session_id=#{session_id}\n"
    {[break, line], state}
  end

  defp render(%{type: :message_streamed, data: data}, state) do
    text = data[:delta] || data[:content] || ""
    {text, %{state | in_text: true}}
  end

  defp render(%{type: :tool_call_started, data: data}, state) do
    {break, state} = maybe_break_line(state)
    name = data[:tool_name] || "unknown"
    id = data[:tool_call_id] || ""
    input = format_tool_input(data[:tool_input])

    tag = colorize("[tool_call_started]", @green, state)
    line = "#{tag} name=#{name} id=#{id}#{input}\n"
    state = %{state | tool_count: state.tool_count + 1}
    {[break, line], state}
  end

  defp render(%{type: :tool_call_completed, data: data}, state) do
    {break, state} = maybe_break_line(state)
    name = data[:tool_name] || "unknown"
    output = format_output(data[:tool_output])

    tag = colorize("[tool_call_completed]", @green, state)
    line = "#{tag} name=#{name}#{output}\n"
    {[break, line], state}
  end

  defp render(%{type: :token_usage_updated, data: data}, state) do
    {break, state} = maybe_break_line(state)
    input_t = data[:input_tokens] || 0
    output_t = data[:output_tokens] || 0
    cost_label = format_verbose_cost(data[:cost_usd])

    tag = dim("[token_usage]", state)
    line = "#{tag} input=#{input_t} output=#{output_t}#{cost_label}\n"
    {[break, line], state}
  end

  defp render(%{type: :message_received, data: data}, state) do
    {break, state} = maybe_break_line(state)
    content = truncate(data[:content] || "", @result_limit)
    role = data[:role] || "assistant"

    tag = colorize("[message_received]", @blue, state)
    line = "#{tag} role=#{role} content=#{content}\n"
    {[break, line], %{state | in_text: false}}
  end

  defp render(%{type: :run_completed, data: data}, state) do
    {break, state} = maybe_break_line(state)
    reason = data[:stop_reason] || "end_turn"
    usage = format_usage(data[:token_usage])
    cost_label = format_verbose_cost(data[:cost_usd])

    tag = colorize("[run_completed]", @blue, state)
    line = "#{tag} stop_reason=#{reason}#{usage}#{cost_label}\n"
    {[break, line], %{state | in_text: false}}
  end

  defp render(%{type: :run_failed, data: data}, state) do
    {break, state} = maybe_break_line(state)
    code = data[:error_code] || "unknown"
    msg = data[:error_message] || "unknown error"

    tag = colorize("[run_failed]", @red, state)
    line = "#{tag} error_code=#{code} error_message=#{truncate(msg, @result_limit)}\n"
    {[break, line], state}
  end

  defp render(%{type: :run_cancelled}, state) do
    {break, state} = maybe_break_line(state)
    tag = colorize("[run_cancelled]", @red, state)
    {[break, "#{tag}\n"], state}
  end

  defp render(%{type: :error_occurred, data: data}, state) do
    {break, state} = maybe_break_line(state)
    code = data[:error_code] || "unknown"
    msg = data[:error_message] || "unknown error"

    tag = colorize("[error]", @red, state)
    line = "#{tag} error_code=#{code} error_message=#{truncate(msg, @result_limit)}\n"
    {[break, line], state}
  end

  # Catch-all
  defp render(%{type: type} = event, state) do
    {break, state} = maybe_break_line(state)
    data_preview = truncate(inspect(event[:data] || %{}), @preview_limit)

    tag = dim("[event]", state)
    line = "#{tag} type=#{type} data=#{data_preview}\n"
    {[break, line], state}
  end

  # -- Helpers --

  defp maybe_break_line(%{in_text: true} = state) do
    {"\n", %{state | in_text: false}}
  end

  defp maybe_break_line(state), do: {"", state}

  defp colorize(text, color, %{color: true}), do: color <> text <> @nc
  defp colorize(text, _color, _state), do: text

  defp dim(text, %{color: true}), do: @dim <> text <> @nc
  defp dim(text, _state), do: text

  defp format_tool_input(nil), do: ""
  defp format_tool_input(input) when input == %{}, do: ""

  defp format_tool_input(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> " input=#{truncate(json, @preview_limit)}"
      _ -> " input=#{truncate(inspect(input), @preview_limit)}"
    end
  end

  defp format_tool_input(input), do: " input=#{truncate(inspect(input), @preview_limit)}"

  defp format_output(nil), do: ""
  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{truncate(to_string(output), @result_limit)}"

  defp format_usage(nil), do: ""

  defp format_usage(%{} = usage) do
    input_t = usage[:input_tokens] || usage["input_tokens"] || 0
    output_t = usage[:output_tokens] || usage["output_tokens"] || 0
    " tokens=#{input_t}/#{output_t}"
  end

  defp format_usage(_), do: ""

  defp format_verbose_cost(nil), do: ""
  defp format_verbose_cost(cost) when is_number(cost), do: " cost=$#{Float.round(cost * 1.0, 6)}"

  defp truncate(nil, _limit), do: ""

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end

  defp truncate(value, limit), do: truncate(inspect(value), limit)
end

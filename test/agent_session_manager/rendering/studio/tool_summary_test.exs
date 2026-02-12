defmodule AgentSessionManager.Rendering.Studio.ToolSummaryTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Studio.ToolSummary

  describe "spinner_text/1" do
    test "formats bash spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "bash",
               input: %{"command" => "mix test test/pubsub_test.exs"}
             }) == "Running: mix test test/pubsub_test.exs"
    end

    test "formats Read spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Read",
               input: %{"file_path" => "lib/rendering/sink.ex"}
             }) == "Reading lib/rendering/sink.ex"
    end

    test "formats Write spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Write",
               input: %{"file_path" => "test/pubsub_sink_test.exs"}
             }) == "Writing test/pubsub_sink_test.exs"
    end

    test "formats Edit spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Edit",
               input: %{"file_path" => "lib/session_manager.ex"}
             }) == "Editing lib/session_manager.ex"
    end

    test "formats Glob spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Glob",
               input: %{"pattern" => "**/*.ex"}
             }) == "Searching for **/*.ex"
    end

    test "formats Grep spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Grep",
               input: %{"pattern" => "defmodule.*Sink", "path" => "lib/"}
             }) == "Searching \"defmodule.*Sink\" in lib/"
    end

    test "formats Task spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "Task",
               input: %{"description" => "Explore codebase"}
             }) == "Running task: Explore codebase"
    end

    test "formats WebFetch spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "WebFetch",
               input: %{"url" => "https://github.com/nshkrdotcom"}
             }) == "Fetching github.com"
    end

    test "formats WebSearch spinner text" do
      assert ToolSummary.spinner_text(%{
               name: "WebSearch",
               input: %{"query" => "elixir pubsub"}
             }) == "Searching: \"elixir pubsub\""
    end

    test "falls back for unknown tools" do
      assert ToolSummary.spinner_text(%{name: "custom_tool", input: %{}}) == "Using custom_tool"
    end

    test "truncates long bash commands to 60 chars" do
      long_command = String.duplicate("a", 70)

      assert ToolSummary.spinner_text(%{
               name: "bash",
               input: %{"command" => long_command}
             }) == "Running: #{String.duplicate("a", 60)}..."
    end

    test "handles nil or empty input gracefully" do
      assert ToolSummary.spinner_text(%{name: "bash", input: nil}) == "Running bash"
      assert ToolSummary.spinner_text(%{name: "Read", input: %{}}) == "Reading file"
    end
  end

  describe "summary_line/1" do
    test "formats successful bash summary" do
      assert ToolSummary.summary_line(%{
               name: "bash",
               input: %{"command" => "mix test"},
               output: String.duplicate("a", 156),
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Ran: mix test (exit 0, 156 chars)"
    end

    test "formats failed bash summary with size" do
      assert ToolSummary.summary_line(%{
               name: "bash",
               input: %{"command" => "mix compile"},
               output: String.duplicate("a", 2400),
               exit_code: 1,
               duration_ms: nil,
               status: :failed
             }) == "Bash failed: mix compile (exit 1, 2.4k chars)"
    end

    test "includes duration for long bash runs" do
      line =
        ToolSummary.summary_line(%{
          name: "bash",
          input: %{"command" => "mix test"},
          output: "ok",
          exit_code: 0,
          duration_ms: 3200,
          status: :completed
        })

      assert line =~ "3.2s"
    end

    test "formats Read summary" do
      output = Enum.map_join(1..72, "\n", fn n -> "line #{n}" end)

      assert ToolSummary.summary_line(%{
               name: "Read",
               input: %{"file_path" => "lib/sink.ex"},
               output: output,
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Read lib/sink.ex (72 lines)"
    end

    test "formats Write summary" do
      content = Enum.map_join(1..138, "\n", fn n -> "line #{n}" end)

      assert ToolSummary.summary_line(%{
               name: "Write",
               input: %{"file_path" => "test/pubsub_sink_test.exs", "content" => content},
               output: nil,
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Wrote test/pubsub_sink_test.exs (138 lines)"
    end

    test "formats Edit summary" do
      assert ToolSummary.summary_line(%{
               name: "Edit",
               input: %{"file_path" => "lib/session_manager.ex"},
               output: nil,
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Edited lib/session_manager.ex"
    end

    test "formats Glob summary" do
      output = Enum.map_join(1..24, "\n", fn n -> "lib/file_#{n}.ex" end)

      assert ToolSummary.summary_line(%{
               name: "Glob",
               input: %{"pattern" => "**/*.ex"},
               output: output,
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Found 24 files matching **/*.ex"
    end

    test "formats Grep summary" do
      output = Enum.map_join(1..8, "\n", fn n -> "lib/file_#{n}.ex:#{n}:defmodule Sink" end)

      assert ToolSummary.summary_line(%{
               name: "Grep",
               input: %{"pattern" => "defmodule.*Sink", "path" => "lib/"},
               output: output,
               exit_code: 0,
               duration_ms: nil,
               status: :completed
             }) == "Found 8 matches for \"defmodule.*Sink\""
    end

    test "formats Task summary" do
      assert ToolSummary.summary_line(%{
               name: "Task",
               input: %{"description" => "Explore codebase"},
               output: nil,
               exit_code: 0,
               duration_ms: 45_200,
               status: :completed
             }) == "Task complete: Explore codebase (45.2s)"
    end

    test "formats unknown tool summary" do
      assert ToolSummary.summary_line(%{
               name: "custom_tool",
               input: %{},
               output: String.duplicate("a", 234),
               exit_code: nil,
               duration_ms: nil,
               status: :completed
             }) == "custom_tool complete (234 chars)"
    end

    test "does not show size when output is nil" do
      assert ToolSummary.summary_line(%{
               name: "custom_tool",
               input: %{},
               output: nil,
               exit_code: nil,
               duration_ms: nil,
               status: :completed
             }) == "custom_tool complete"
    end

    test "does not show size when output is empty" do
      assert ToolSummary.summary_line(%{
               name: "custom_tool",
               input: %{},
               output: "",
               exit_code: nil,
               duration_ms: nil,
               status: :completed
             }) == "custom_tool complete"
    end

    test "handles structured tool output map without raising" do
      line =
        ToolSummary.summary_line(%{
          name: "bash",
          input: %{"command" => "rg -n \"version:\" mix.exs"},
          output: %{
            output: "10:      version: @version,\n",
            status: :completed,
            exit_code: 0
          },
          exit_code: nil,
          duration_ms: nil,
          status: :completed
        })

      assert line =~ "Ran: rg -n \"version:\" mix.exs"
      assert line =~ "exit 0"
      assert line =~ "chars"
    end
  end

  describe "preview_lines/2" do
    test "returns last 3 non-empty lines for bash output" do
      output = "\nline1\n\nline2\nline3\nline4\n"

      assert ToolSummary.preview_lines(%{name: "bash", output: output}, 3) == [
               "line2",
               "line3",
               "line4"
             ]
    end

    test "returns [] for empty output" do
      assert ToolSummary.preview_lines(%{name: "bash", output: ""}, 3) == []
      assert ToolSummary.preview_lines(%{name: "bash", output: nil}, 3) == []
    end

    test "returns all lines when output has fewer than max lines" do
      assert ToolSummary.preview_lines(%{name: "bash", output: "a\nb\n"}, 3) == ["a", "b"]
    end

    test "extracts preview lines from structured tool output map" do
      output = %{
        output: "line1\nline2\nline3\nline4\n",
        status: :completed,
        exit_code: 0
      }

      assert ToolSummary.preview_lines(%{name: "bash", output: output}, 2) == ["line3", "line4"]
    end
  end

  describe "format_size/1" do
    test "formats size values" do
      assert ToolSummary.format_size(nil) == ""
      assert ToolSummary.format_size(0) == "0 chars"
      assert ToolSummary.format_size(500) == "500 chars"
      assert ToolSummary.format_size(1500) == "1.5k chars"
      assert ToolSummary.format_size(15_000) == "15k chars"
    end
  end

  describe "shorten_path/2" do
    test "returns unchanged short path" do
      assert ToolSummary.shorten_path("lib/rendering/sink.ex", 60) == "lib/rendering/sink.ex"
    end

    test "shortens long paths while keeping first and last segments" do
      long_path = "lib/agent_session_manager/deep/nested/rendering/sink.ex"
      assert ToolSummary.shorten_path(long_path, 20) == "lib/.../rendering/sink.ex"
    end
  end
end

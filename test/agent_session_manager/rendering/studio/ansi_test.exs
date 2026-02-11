defmodule AgentSessionManager.Rendering.Studio.ANSITest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Rendering.Studio.ANSI

  describe "color helpers" do
    test "wraps text with ANSI color/style codes" do
      assert ANSI.green("text") == "\e[0;32mtext\e[0m"
      assert ANSI.red("text") == "\e[0;31mtext\e[0m"
      assert ANSI.blue("text") == "\e[0;34mtext\e[0m"
      assert ANSI.cyan("text") == "\e[0;36mtext\e[0m"
      assert ANSI.magenta("text") == "\e[0;35mtext\e[0m"
      assert ANSI.dim("text") == "\e[2mtext\e[0m"
      assert ANSI.bold("text") == "\e[1mtext\e[0m"
    end

    test "returns plain text when disabled" do
      assert ANSI.green("text", false) == "text"
      assert ANSI.red("text", false) == "text"
      assert ANSI.blue("text", false) == "text"
      assert ANSI.cyan("text", false) == "text"
      assert ANSI.magenta("text", false) == "text"
      assert ANSI.dim("text", false) == "text"
      assert ANSI.bold("text", false) == "text"
    end

    test "returns empty string for empty input" do
      assert ANSI.green("") == ""
      assert ANSI.red("") == ""
      assert ANSI.blue("") == ""
      assert ANSI.cyan("") == ""
      assert ANSI.magenta("") == ""
      assert ANSI.dim("") == ""
      assert ANSI.bold("") == ""
    end
  end

  describe "symbols" do
    test "returns status symbols" do
      assert ANSI.success() == "✓"
      assert ANSI.failure() == "✗"
      assert ANSI.info() == "●"
      assert ANSI.running() == "◐"
    end
  end

  describe "cursor control" do
    test "returns clear line escape sequence" do
      assert ANSI.clear_line() == "\r\e[2K"
    end

    test "returns cursor up sequence" do
      assert ANSI.cursor_up(3) == "\e[3A"
    end
  end
end

defmodule AgentSessionManager.Rendering.Studio.ANSI do
  @moduledoc """
  ANSI terminal utilities for the StudioRenderer pipeline.

  Provides color formatting, cursor control, and Unicode status symbols.
  All color functions accept an `enabled?` flag (default `true`) to support
  non-TTY and color-disabled environments.
  """

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @magenta "\e[0;35m"
  @cyan "\e[0;36m"
  @dim "\e[2m"
  @bold "\e[1m"
  @reset "\e[0m"

  @spec red(String.t(), boolean()) :: String.t()
  def red(text, enabled? \\ true), do: colorize(text, @red, enabled?)

  @spec green(String.t(), boolean()) :: String.t()
  def green(text, enabled? \\ true), do: colorize(text, @green, enabled?)

  @spec blue(String.t(), boolean()) :: String.t()
  def blue(text, enabled? \\ true), do: colorize(text, @blue, enabled?)

  @spec cyan(String.t(), boolean()) :: String.t()
  def cyan(text, enabled? \\ true), do: colorize(text, @cyan, enabled?)

  @spec magenta(String.t(), boolean()) :: String.t()
  def magenta(text, enabled? \\ true), do: colorize(text, @magenta, enabled?)

  @spec dim(String.t(), boolean()) :: String.t()
  def dim(text, enabled? \\ true), do: colorize(text, @dim, enabled?)

  @spec bold(String.t(), boolean()) :: String.t()
  def bold(text, enabled? \\ true), do: colorize(text, @bold, enabled?)

  @spec success() :: String.t()
  def success, do: "✓"

  @spec failure() :: String.t()
  def failure, do: "✗"

  @spec info() :: String.t()
  def info, do: "●"

  @spec running() :: String.t()
  def running, do: "◐"

  @spec clear_line() :: String.t()
  def clear_line, do: "\r\e[2K"

  @spec cursor_up(non_neg_integer()) :: String.t()
  def cursor_up(n), do: "\e[#{n}A"

  @spec tty?() :: boolean()
  def tty? do
    match?({:ok, _}, :io.columns(:stdio))
  end

  defp colorize("", _color, _enabled?), do: ""
  defp colorize(text, _color, false), do: text
  defp colorize(text, color, true), do: color <> text <> @reset
end

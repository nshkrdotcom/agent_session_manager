defmodule AgentSessionManager.Test.Models do
  @moduledoc """
  Centralized model name constants and reasoning level fixtures for tests.

  All test files should reference these functions instead of hardcoding model
  strings. Changing a model name here updates every test that uses it.
  """

  @doc "Default Claude model used in most test fixtures."
  def claude_model, do: "claude-haiku-4-5-20251001"

  @doc "Claude Sonnet model used in rendering and AMP mock fixtures."
  def claude_sonnet_model, do: "claude-sonnet-4-5-20250929"

  @doc "Claude Opus model used in cost and policy test fixtures."
  def claude_opus_model, do: "claude-opus-4-6"

  @doc "Codex model used in Codex adapter test fixtures."
  def codex_model, do: "gpt-5.3-codex"

  @doc "High reasoning effort level for Codex test fixtures."
  def reasoning_effort_high, do: "xhigh"

  @doc "Medium reasoning effort level for Codex test fixtures."
  def reasoning_effort_medium, do: :medium
end

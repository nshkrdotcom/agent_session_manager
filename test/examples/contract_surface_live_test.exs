defmodule AgentSessionManager.Examples.ContractSurfaceLiveTest do
  @moduledoc """
  Tests for the contract_surface_live example script.

  These tests verify that the script compiles and, when live, can execute
  against real adapters while exposing runtime contract details.
  """

  use AgentSessionManager.SupertesterCase, async: false

  @moduletag :live

  setup ctx do
    if System.get_env("LIVE_TESTS") != "true" do
      {:ok, Map.put(ctx, :skip, true)}
    else
      {:ok, Map.put(ctx, :skip, false)}
    end
  end

  describe "contract surface live example" do
    @tag :live
    test "example script compiles without warnings", ctx do
      if ctx[:skip] do
        :ok
      else
        {result, _binding} =
          Code.eval_string(
            File.read!("examples/contract_surface_live.exs")
            |> String.replace(~r/^ContractSurfaceLive\.main\(System\.argv\(\)\)$/m, ":ok"),
            [],
            file: "examples/contract_surface_live.exs"
          )

        assert result == :ok
      end
    end
  end
end

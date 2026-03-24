defmodule ASM.Extensions.ProviderSDK.InvocationContractTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.Dispatch

  defmodule ExampleOptionalModule do
    @moduledoc false

    def call(left, right), do: {:ok, left, right}
  end

  test "dispatch helper invokes provider entrypoints without static remote calls" do
    assert {:ok, :left, :right} =
             Dispatch.invoke_2(ExampleOptionalModule, :call, :left, :right)
  end

  test "optional provider entrypoints stay behind dynamic invocation" do
    claude_source =
      File.read!(Path.expand("../../../../lib/asm/extensions/provider_sdk/claude.ex", __DIR__))

    assert claude_source =~ "Dispatch.invoke_2(module, :start_link, options, client_opts)"
    refute claude_source =~ "module.start_link(options, client_opts)"

    codex_source =
      File.read!(Path.expand("../../../../lib/asm/extensions/provider_sdk/codex.ex", __DIR__))

    assert codex_source =~ "Dispatch.invoke_2(module, :connect, options, connect_opts)"
    refute codex_source =~ "module.connect(options, connect_opts)"
  end
end

defmodule ASM.BoundaryEnforcementTest do
  use ASM.TestCase

  alias Boundary.Mix.View

  @extension_boundaries [
    ASM.Extensions.Persistence,
    ASM.Extensions.Routing,
    ASM.Extensions.Policy,
    ASM.Extensions.Rendering,
    ASM.Extensions.Workspace,
    ASM.Extensions.PubSub,
    ASM.Extensions.Provider,
    ASM.Extensions.ProviderSDK
  ]

  test "boundary compiler is enabled" do
    compilers = Mix.Project.config()[:compilers] || Mix.compilers()
    assert :boundary in compilers
  end

  test "boundary dependency remains available to dependency-driven dev compiles" do
    boundary_dep =
      Mix.Project.config()[:deps]
      |> Enum.find(fn
        {:boundary, _requirement, _opts} -> true
        _other -> false
      end)

    assert {:boundary, "~> 0.10.4", opts} = boundary_dep
    assert opts[:runtime] == false
    refute Keyword.has_key?(opts, :only)
  end

  test "core and extension boundaries are declared" do
    view = View.build()
    asm_boundary = Boundary.fetch!(view, ASM)

    assert asm_boundary.deps == []

    Enum.each(@extension_boundaries, fn boundary ->
      assert Boundary.fetch!(view, boundary).deps == [{ASM, :runtime}]
    end)
  end

  test "kernel boundary does not export extension namespaces" do
    asm_boundary = Boundary.fetch!(View.build(), ASM)

    Enum.each(@extension_boundaries, fn boundary ->
      refute boundary in asm_boundary.exports
    end)
  end

  test "extension lifecycle stays outside core application child specs" do
    source = File.read!("lib/asm/application.ex")
    refute source =~ "ASM.Extensions."
  end
end

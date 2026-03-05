defmodule ASM.BoundaryEnforcementTest do
  use ASM.TestCase

  @extension_boundaries [
    ASM.Extensions.Persistence,
    ASM.Extensions.Routing,
    ASM.Extensions.Policy,
    ASM.Extensions.Rendering,
    ASM.Extensions.Workspace,
    ASM.Extensions.PubSub,
    ASM.Extensions.Provider
  ]

  test "boundary compiler is enabled" do
    compilers = Mix.Project.config()[:compilers] || Mix.compilers()
    assert :boundary in compilers
  end

  test "core and extension boundaries are declared" do
    assert Code.ensure_loaded?(ASM)
    assert function_exported?(ASM, :__boundary__, 1)
    assert ASM.__boundary__(:deps) == []

    Enum.each(@extension_boundaries, fn boundary ->
      assert Code.ensure_loaded?(boundary)
      assert function_exported?(boundary, :__boundary__, 1)
      assert boundary.__boundary__(:deps) == [ASM]
    end)
  end

  test "checker reports core-to-extension dependency violations" do
    sources = [
      {"asm.ex", "defmodule ASM do\n  use Boundary, deps: [], exports: [ASM]\nend\n"},
      {"ext.ex",
       "defmodule ASM.Extensions.Persistence do\n  use Boundary, deps: [ASM], exports: []\nend\n"},
      {"violation.ex",
       "defmodule ASM.Run.BoundaryProbe do\n  alias ASM.Extensions.Persistence\n  def probe, do: Persistence\nend\n"}
    ]

    violations = Boundary.Checker.violations_for_sources(sources)

    assert Enum.any?(violations, fn violation ->
             violation.module == ASM.Run.BoundaryProbe and
               violation.referenced_boundary == ASM.Extensions.Persistence
           end)
  end

  test "extension lifecycle stays outside core application child specs" do
    source = File.read!("lib/asm/application.ex")
    refute source =~ "ASM.Extensions."
  end
end

defmodule ASM.Provider.ResolverTest do
  use ExUnit.Case, async: true

  alias ASM.Provider
  alias ASM.Provider.Resolver

  test "explicit cli_path takes priority when executable" do
    assert {:ok, spec} =
             Resolver.resolve(:claude,
               cli_path: "/tmp/claude",
               file_exists?: fn _ -> true end,
               executable?: fn _ -> true end
             )

    assert spec.program == "/tmp/claude"
    assert spec.argv_prefix == []
  end

  test "env var is used when explicit path absent" do
    assert {:ok, spec} =
             Resolver.resolve(:codex_exec,
               env: fn
                 "CODEX_PATH" -> "/usr/local/bin/codex"
                 _ -> nil
               end,
               file_exists?: fn _ -> true end,
               executable?: fn _ -> true end
             )

    assert spec.program == "/usr/local/bin/codex"
  end

  test "path lookup fallback uses provider binary names" do
    assert {:ok, spec} =
             Resolver.resolve(:claude,
               env: fn _ -> nil end,
               find_executable: fn
                 "claude" -> "/bin/claude"
                 _ -> nil
               end
             )

    assert spec.program == "/bin/claude"
  end

  test "gemini can fallback to npx command spec" do
    assert {:ok, spec} =
             Resolver.resolve(:gemini,
               env: fn
                 "GEMINI_NO_NPX" -> nil
                 _ -> nil
               end,
               find_executable: fn
                 "npm" -> nil
                 "npx" -> "/usr/bin/npx"
                 _ -> nil
               end
             )

    assert spec.program == "/usr/bin/npx"
    assert spec.argv_prefix == ["--yes", "--package", "@google/gemini-cli", "gemini"]
  end

  test "returns typed error when no strategy resolves a binary" do
    assert {:error, error} =
             Resolver.resolve(:claude,
               env: fn _ -> nil end,
               find_executable: fn _ -> nil end
             )

    assert error.kind == :cli_not_found
    assert error.domain == :provider
  end

  test "resolves provider struct input" do
    assert {:ok, provider} = Provider.resolve(:claude)

    assert {:ok, spec} =
             Resolver.resolve(provider,
               env: fn _ -> nil end,
               find_executable: fn
                 "claude" -> "/bin/claude"
                 _ -> nil
               end
             )

    assert spec.program == "/bin/claude"
  end

  test "env map option does not crash and still allows PATH fallback" do
    assert {:ok, spec} =
             Resolver.resolve(:claude,
               env: %{},
               find_executable: fn
                 "claude" -> "/bin/claude"
                 _ -> nil
               end
             )

    assert spec.program == "/bin/claude"
  end

  test "env map can satisfy provider env var path lookup" do
    assert {:ok, spec} =
             Resolver.resolve(:codex_exec,
               env: %{"CODEX_PATH" => "/usr/local/bin/codex"},
               file_exists?: fn _ -> true end,
               executable?: fn _ -> true end,
               find_executable: fn _ -> nil end
             )

    assert spec.program == "/usr/local/bin/codex"
  end
end

defmodule ASM.Options.CursorTest do
  use ASM.TestCase

  alias ASM.{Options, Provider}
  alias ASM.Options.{ProviderNativeOptionError, UnsupportedOptionError}
  alias ASM.Schema.ProviderOptions, as: ProviderOptionsSchema

  @schema Provider.resolve!(:cursor).options_schema

  test "validates Cursor native options behind the provider schema" do
    assert {:ok, validated} =
             Options.validate(
               [
                 provider: :cursor,
                 model: "composer-2.5-fast",
                 permission_mode: :bypass,
                 mode: :ask,
                 sandbox: :enabled,
                 approve_mcps: true,
                 worktree: "phase-2",
                 worktree_base: "main",
                 skip_worktree_setup: true,
                 plugin_dirs: ["/plugins/a", "/plugins/b"],
                 headers: [{"X-Trace", "trace-1"}]
               ],
               @schema
             )

    assert validated[:provider] == :cursor
    assert validated[:permission_mode] == :bypass
    assert validated[:provider_permission_mode] == :bypass
    assert validated[:mode] == :ask
    assert validated[:sandbox] == :enabled
    assert validated[:approve_mcps] == true
    assert validated[:worktree] == "phase-2"
    assert validated[:worktree_base] == "main"
    assert validated[:skip_worktree_setup] == true
    assert validated[:plugin_dirs] == ["/plugins/a", "/plugins/b"]
    assert validated[:headers] == [{"X-Trace", "trace-1"}]
    assert {:ok, ^validated} = ProviderOptionsSchema.validate(validated)
  end

  test "keeps Cursor ask mode separate from permission modes" do
    assert {:ok, validated} = Options.validate([provider: :cursor, mode: :ask], @schema)
    assert validated[:mode] == :ask

    assert {:error, error} =
             Options.validate([provider: :cursor, permission_mode: :ask], @schema)

    assert String.contains?(error.message, "Permission mode :ask is not valid")
  end

  test "does not admit a duplicate workspace option" do
    assert {:error, error} =
             Options.validate([provider: :cursor, workspace: "/tmp/cursor"], @schema)

    assert String.contains?(error.message, "unknown options [:workspace]")
  end

  test "strict preflight rejects Cursor native options outside native boundaries" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:cursor, approve_mcps: true)

    assert error.key == :approve_mcps
    assert error.provider == :cursor

    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:cursor, worktree: "feature")

    assert error.key == :worktree
    assert error.provider == :cursor
  end

  test "strict preflight treats workspace as an unsupported common key" do
    assert {:error, %UnsupportedOptionError{} = error} =
             Options.preflight(:cursor, workspace: "/tmp/cursor")

    assert error.key == :workspace
    assert error.provider == :cursor
  end

  test "finalize_provider_opts attaches the Cursor model payload and preserves native options" do
    assert {:ok, validated} =
             Options.validate(
               [provider: :cursor, model: "composer-2.5-fast", mode: :plan],
               @schema
             )

    assert {:ok, finalized} =
             Options.finalize_provider_opts(:cursor, Keyword.delete(validated, :provider))

    payload = Keyword.fetch!(finalized, :model_payload)

    assert payload.provider == :cursor
    assert payload.requested_model == "composer-2.5-fast"
    assert payload.resolved_model == "composer-2.5-fast"
    assert finalized[:mode] == :plan
    refute Keyword.has_key?(finalized, :model)
  end
end

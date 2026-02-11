# Workspace Snapshots

Feature 3 adds optional workspace instrumentation to `SessionManager.execute_run/4`:

- pre-run snapshot
- post-run snapshot
- workspace diff computation
- run metadata/result enrichment
- optional rollback on failure (git backend only in MVP)

## Enable Workspace Flow

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  workspace: [
    enabled: true,
    path: "/path/to/workspace",
    strategy: :auto,
    capture_patch: true,
    max_patch_bytes: 1_048_576,
    rollback_on_failure: false
  ]
)
```

Workspace options:

- `enabled` - activates workspace flow when true
- `path` - directory to snapshot/diff
- `strategy` - `:auto | :git | :hash`
- `capture_patch` - include full patch when possible
- `max_patch_bytes` - patch size cap
- `rollback_on_failure` - rollback failed run changes (git only)
- `artifact_store` - (Phase 2) artifact store pid for offloading large patches
- `ignore` - (Phase 2) configurable ignore rules for hash backend (see below)

## Execution Flow

When workspace is enabled, `SessionManager` runs:

1. take pre snapshot (`label: :before`)
2. execute adapter run
3. take post snapshot (`label: :after` or `:after_failure`)
4. compute diff
5. enrich run metadata (compact summary)
6. optionally attach full patch if within cap
7. optionally rollback on failure when backend is `:git`

## Event Types

Feature 3 adds two event atoms to `Core.Event`:

- `:workspace_snapshot_taken`
- `:workspace_diff_computed`

Typical payloads:

- snapshot: `%{label: :before, backend: :git, ref: "..."}`
- diff: `%{files_changed: 3, insertions: 40, deletions: 12, has_patch: true}`

## Result and Metadata

`execute_run/4` success results include `:workspace` details:

- `backend`
- `before_snapshot`
- `after_snapshot`
- `diff`

Run metadata stores a compact summary under `run.metadata.workspace`:

- backend and snapshot refs
- diff counts
- changed paths
- optional patch when available and within cap

## Backends

`AgentSessionManager.Workspace.Workspace` delegates to backend modules:

- `GitBackend` - snapshots, diffs, rollback support
- `HashBackend` - snapshots and diffs only

`strategy: :auto` chooses git when repository metadata is detected, otherwise hash.

### Git Backend: Untracked File Support (Phase 2)

Git snapshots now capture the full workspace state including untracked files. The implementation uses an alternate `GIT_INDEX_FILE` to stage all content without mutating `HEAD` or leaving stash entries.

Snapshot metadata includes:

- `head_ref` - the commit `HEAD` pointed to at capture time
- `dirty` - `true` when workspace state differs from `HEAD`
- `includes_untracked` - always `true` (untracked files are included)

### Hash Backend: Configurable Ignore Rules (Phase 2)

The hash backend supports configurable ignore rules via the `ignore:` option:

```elixir
{:ok, snapshot} = HashBackend.take_snapshot(path,
  ignore: [
    paths: ["vendor", "logs", "tmp"],
    globs: ["*.log", "**/*.bak"]
  ]
)
```

- `paths` - directory names to exclude (additive to defaults: `.git`, `deps`, `_build`, `node_modules`)
- `globs` - glob patterns to exclude files by name. Supports `*`, `**`, and `?` wildcards.

The same ignore rules should be passed to both snapshot calls to ensure consistent diffs.

## Artifact Store (Phase 2)

`AgentSessionManager.Ports.ArtifactStore` provides a port for storing large blobs (patches, manifests) separately from run metadata.

### File-Backed Adapter

```elixir
{:ok, artifact_store} = FileArtifactStore.start_link(root: "/tmp/artifacts")

:ok = ArtifactStore.put(artifact_store, "patch-abc123", patch_data)
{:ok, data} = ArtifactStore.get(artifact_store, "patch-abc123")
:ok = ArtifactStore.delete(artifact_store, "patch-abc123")
```

### Artifact References in Workspace Metadata

When an `artifact_store` is configured in workspace options, large patches are stored as artifacts and the run metadata contains a `patch_ref` key instead of the raw patch:

```elixir
{:ok, result} = SessionManager.execute_run(store, adapter, run.id,
  workspace: [
    enabled: true,
    path: repo_path,
    capture_patch: true,
    artifact_store: artifact_store
  ]
)

# result.workspace.diff contains:
# - patch_ref: "patch_<from_ref>_<to_ref>_<id>"  (artifact key)
# - patch_bytes: 1234                              (original patch size)
# - patch: nil                                     (not embedded)

# Retrieve the full patch from the artifact store:
{:ok, full_patch} = ArtifactStore.get(artifact_store, result.workspace.diff.patch_ref)
```

Without an `artifact_store` configured, patches are embedded directly in the result.

## Rollback Scope

Rollback behavior is intentionally constrained:

- `rollback_on_failure: true` with git backend: rollback runs
- `rollback_on_failure: true` with hash backend: returns configuration error before adapter execution
- direct hash rollback calls return `{:error, ...}`

Git rollback creates a safety tag before reset.

## `run_once/4` Support

`run_once/4` forwards workspace options:

```elixir
{:ok, result} = SessionManager.run_once(store, adapter, input,
  workspace: [enabled: true, path: File.cwd!(), strategy: :auto]
)
```

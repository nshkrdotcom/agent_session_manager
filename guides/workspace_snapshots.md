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

## Rollback Scope (MVP)

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

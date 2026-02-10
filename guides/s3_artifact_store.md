# S3ArtifactStore

`AgentSessionManager.Adapters.S3ArtifactStore` stores binary artifacts in
S3-compatible object storage. Use it for workspace patches, snapshot manifests,
and any large blobs that should not live in a relational database. It works with
AWS S3, MinIO, DigitalOcean Spaces, Backblaze B2, and any other service that
implements the S3 API.

## Prerequisites

Add the ExAws dependencies to your `mix.exs`:

```elixir
def deps do
  [
    {:agent_session_manager, "~> 0.6.0"},
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},     # required by ex_aws for XML response parsing
    {:hackney, "~> 1.20"}       # HTTP client for ex_aws
  ]
end
```

Configure ExAws with your credentials. The simplest approach is environment
variables:

```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
```

Or configure in `config/config.exs`:

```elixir
config :ex_aws,
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: "us-east-1"
```

For S3-compatible services (MinIO, DigitalOcean Spaces, etc.), set the endpoint:

```elixir
config :ex_aws, :s3,
  scheme: "https://",
  host: "nyc3.digitaloceanspaces.com",
  region: "nyc3"
```

## Configuration

Start the store with a bucket name and optional prefix:

```elixir
alias AgentSessionManager.Adapters.S3ArtifactStore

# Minimal
{:ok, store} = S3ArtifactStore.start_link(bucket: "my-artifacts")

# With a key prefix and registered name
{:ok, store} = S3ArtifactStore.start_link(
  bucket: "my-artifacts",
  prefix: "asm/artifacts/",
  name: :artifact_store
)

# With a custom S3 client (see below)
{:ok, store} = S3ArtifactStore.start_link(
  bucket: "my-artifacts",
  client: MyApp.MockS3Client
)
```

### Options

| Option    | Required | Default | Description |
|-----------|----------|---------|-------------|
| `:bucket` | Yes | -- | S3 bucket name |
| `:prefix` | No  | `""` | Key prefix prepended to all object keys |
| `:client` | No  | `S3ArtifactStore.ExAwsClient` | Module implementing the `S3Client` behaviour |
| `:name`   | No  | -- | GenServer name for registration |

### Key Structure

Objects are stored at `{prefix}{key}`. For example, with
`prefix: "asm/artifacts/"` and key `"patch-abc123"`, the full S3 object key is:

```
asm/artifacts/patch-abc123
```

Using a prefix keeps all AgentSessionManager artifacts organized under a common
path and avoids collisions with other data in the same bucket.

### Supervision Tree

```elixir
children = [
  {S3ArtifactStore,
    bucket: "my-artifacts",
    prefix: "asm/",
    name: :artifact_store}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## The S3Client Behaviour

The adapter delegates actual S3 API calls to a module that implements
`AgentSessionManager.Adapters.S3ArtifactStore.S3Client`:

```elixir
@callback put_object(bucket :: String.t(), key :: String.t(), data :: binary(), opts :: keyword()) ::
            :ok | {:error, term()}

@callback get_object(bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
            {:ok, binary()} | {:error, term()}

@callback delete_object(bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}
```

The default implementation, `S3ArtifactStore.ExAwsClient`, uses `ExAws.S3` and
`ExAws.request()` under the hood. It maps a 404 HTTP response to
`{:error, :not_found}` for clean error handling.

### Custom Client for Testing

Provide a mock or stub implementation for tests:

```elixir
defmodule MyApp.TestS3Client do
  @behaviour AgentSessionManager.Adapters.S3ArtifactStore.S3Client

  @impl true
  def put_object(_bucket, key, data, _opts) do
    Agent.update(:test_s3, fn state -> Map.put(state, key, data) end)
    :ok
  end

  @impl true
  def get_object(_bucket, key, _opts) do
    case Agent.get(:test_s3, fn state -> Map.get(state, key) end) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  @impl true
  def delete_object(_bucket, key, _opts) do
    Agent.update(:test_s3, fn state -> Map.delete(state, key) end)
    :ok
  end
end
```

Use it in tests:

```elixir
Agent.start_link(fn -> %{} end, name: :test_s3)

{:ok, store} = S3ArtifactStore.start_link(
  bucket: "test-bucket",
  client: MyApp.TestS3Client
)
```

You can also use [Mox](https://hexdocs.pm/mox) to define expectations:

```elixir
Mox.defmock(MockS3Client, for: AgentSessionManager.Adapters.S3ArtifactStore.S3Client)

{:ok, store} = S3ArtifactStore.start_link(
  bucket: "test-bucket",
  client: MockS3Client
)

expect(MockS3Client, :put_object, fn _bucket, _key, _data, _opts -> :ok end)
```

## Usage Examples

```elixir
alias AgentSessionManager.Adapters.S3ArtifactStore
alias AgentSessionManager.Ports.ArtifactStore

{:ok, store} = S3ArtifactStore.start_link(
  bucket: "my-artifacts",
  prefix: "asm/"
)

# Store an artifact
patch_data = "--- a/file.ex\n+++ b/file.ex\n@@ -1 +1 @@\n-old\n+new"
:ok = ArtifactStore.put(store, "patch-abc123", patch_data)

# Retrieve it
{:ok, data} = ArtifactStore.get(store, "patch-abc123")
data
#=> "--- a/file.ex\n+++ b/file.ex\n@@ -1 +1 @@\n-old\n+new"

# Delete it
:ok = ArtifactStore.delete(store, "patch-abc123")

# Deleting a non-existent key is a no-op
:ok = ArtifactStore.delete(store, "does-not-exist")

# Retrieving a missing key returns an error
{:error, %AgentSessionManager.Core.Error{code: :not_found}} =
  ArtifactStore.get(store, "does-not-exist")
```

## Composing with a SessionStore

A common production pattern is to store sessions in a database and artifacts in
S3. Use `CompositeSessionStore` to combine them:

```elixir
alias AgentSessionManager.Adapters.{EctoSessionStore, S3ArtifactStore, CompositeSessionStore}

{:ok, session_store} = EctoSessionStore.start_link(repo: MyApp.Repo)
{:ok, artifact_store} = S3ArtifactStore.start_link(bucket: "my-artifacts")

{:ok, store} = CompositeSessionStore.start_link(
  session_store: session_store,
  artifact_store: artifact_store,
  name: :unified_store
)
```

The composite store implements both `SessionStore` and `ArtifactStore`
behaviours, so it can be used anywhere either port is expected.

## Notes and Caveats

- **S3-compatible means any service that speaks the S3 API.** Configure the
  endpoint in your ExAws config to point at MinIO, DigitalOcean Spaces, or any
  other compatible service.

- **Binary data only.** The `put/4` callback accepts `iodata()` and converts it
  to a binary with `IO.iodata_to_binary/1` before upload. The `get/3` callback
  returns a plain `binary()`.

- **No streaming.** The current implementation uploads and downloads entire
  objects in memory. For very large artifacts (hundreds of megabytes), consider
  a custom `S3Client` implementation that uses multipart uploads.

- **Idempotent deletes.** Deleting a key that does not exist returns `:ok`,
  matching the ArtifactStore contract.

- **ExAws must be configured.** The default `ExAwsClient` calls
  `ExAws.request()`, which reads credentials from application config and
  environment variables. Make sure ExAws is properly configured before starting
  the store.

- **Error wrapping.** S3 errors are wrapped in
  `%AgentSessionManager.Core.Error{code: :storage_error}`. A 404 from S3 is
  converted to `%Error{code: :not_found}`.

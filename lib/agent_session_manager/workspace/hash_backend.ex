defmodule AgentSessionManager.Workspace.HashBackend do
  @moduledoc """
  Hash-based workspace backend for non-git directories.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, Snapshot}

  @excluded_roots [".git", "deps", "_build", "node_modules"]

  @spec take_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def take_snapshot(path, opts \\ []) when is_binary(path) do
    with :ok <- validate_directory(path) do
      file_hashes = collect_file_hashes(path)
      reference = digest_file_hashes(file_hashes)

      {:ok,
       %Snapshot{
         backend: :hash,
         path: Path.expand(path),
         ref: reference,
         label: Keyword.get(opts, :label),
         captured_at: DateTime.utc_now(),
         metadata: %{file_hashes: file_hashes}
       }}
    end
  end

  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: {:ok, Diff.t()} | {:error, Error.t()}
  def diff(before_snapshot, after_snapshot, opts \\ [])

  def diff(
        %Snapshot{backend: :hash} = before_snapshot,
        %Snapshot{backend: :hash} = after_snapshot,
        _opts
      ) do
    before_hashes = Map.get(before_snapshot.metadata, :file_hashes, %{})
    after_hashes = Map.get(after_snapshot.metadata, :file_hashes, %{})

    changed_paths =
      before_hashes
      |> Map.keys()
      |> Enum.concat(Map.keys(after_hashes))
      |> Enum.uniq()
      |> Enum.filter(fn path ->
        Map.get(before_hashes, path) != Map.get(after_hashes, path)
      end)
      |> Enum.sort()

    {:ok,
     %Diff{
       backend: :hash,
       from_ref: before_snapshot.ref,
       to_ref: after_snapshot.ref,
       files_changed: length(changed_paths),
       insertions: 0,
       deletions: 0,
       changed_paths: changed_paths,
       patch: nil,
       metadata: %{}
     }}
  end

  def diff(_before, _after, _opts) do
    {:error, Error.new(:validation_error, "Hash diff requires hash snapshots")}
  end

  @spec rollback(Snapshot.t(), keyword()) :: :ok | {:error, Error.t()}
  def rollback(snapshot, opts \\ [])

  def rollback(%Snapshot{backend: :hash}, _opts) do
    {:error,
     Error.new(
       :invalid_operation,
       "Rollback is not supported for hash backend in MVP"
     )}
  end

  def rollback(_snapshot, _opts) do
    {:error, Error.new(:validation_error, "Hash rollback requires hash snapshot")}
  end

  defp validate_directory(path) do
    cond do
      path == "" ->
        {:error, Error.new(:validation_error, "workspace path cannot be empty")}

      not File.dir?(path) ->
        {:error, Error.new(:validation_error, "workspace path is not a directory: #{path}")}

      true ->
        :ok
    end
  end

  defp collect_file_hashes(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%{}, fn absolute_path, acc ->
      relative_path = Path.relative_to(absolute_path, path)

      if excluded?(relative_path) do
        acc
      else
        Map.put(acc, relative_path, file_sha256(absolute_path))
      end
    end)
  end

  defp excluded?(relative_path) do
    relative_path
    |> String.split("/", trim: true)
    |> case do
      [root | _] -> root in @excluded_roots
      _ -> false
    end
  end

  defp file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path))
    |> Base.encode16(case: :lower)
  end

  defp digest_file_hashes(file_hashes) do
    payload =
      file_hashes
      |> Enum.sort_by(fn {path, _hash} -> path end)
      |> Enum.map_join("\n", fn {path, hash} -> "#{path}:#{hash}" end)

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end

defmodule AgentSessionManager.Workspace.HashBackend do
  @moduledoc """
  Hash-based workspace backend for non-git directories.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, Snapshot}

  @default_excluded_roots [".git", "deps", "_build", "node_modules"]

  @spec take_snapshot(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def take_snapshot(path, opts \\ []) when is_binary(path) do
    with :ok <- validate_directory(path) do
      ignore_config = Keyword.get(opts, :ignore, [])
      file_hashes = collect_file_hashes(path, ignore_config)
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

  defp collect_file_hashes(path, ignore_config) do
    extra_paths = Keyword.get(ignore_config, :paths, [])
    globs = Keyword.get(ignore_config, :globs, [])
    excluded_roots = @default_excluded_roots ++ extra_paths

    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%{}, fn absolute_path, acc ->
      relative_path = Path.relative_to(absolute_path, path)

      if excluded_by_root?(relative_path, excluded_roots) or
           excluded_by_glob?(relative_path, globs) do
        acc
      else
        Map.put(acc, relative_path, file_sha256(absolute_path))
      end
    end)
  end

  defp excluded_by_root?(relative_path, excluded_roots) do
    relative_path
    |> String.split("/", trim: true)
    |> case do
      [root | _] -> root in excluded_roots
      _ -> false
    end
  end

  defp excluded_by_glob?(_relative_path, []), do: false

  defp excluded_by_glob?(relative_path, globs) do
    Enum.any?(globs, fn glob ->
      glob_matches?(relative_path, glob)
    end)
  end

  # Converts a glob pattern to a regex and matches against the relative path.
  # Supports: * (anything except /), ** (anything including /), ? (single char)
  # For simple globs like "*.log", also tries matching against just the basename.
  defp glob_matches?(relative_path, glob) do
    regex = glob_to_regex(glob)

    Regex.match?(regex, relative_path) or
      (not String.contains?(glob, "/") and
         Regex.match?(regex, Path.basename(relative_path)))
  end

  defp glob_to_regex(glob) do
    # Build regex from glob pattern. We use a manual approach to avoid
    # placeholder collisions with the replacement pipeline.
    parts =
      glob
      |> String.graphemes()
      |> build_regex_parts([], false)
      |> Enum.reverse()
      |> Enum.join()

    Regex.compile!("^#{parts}$")
  end

  # Handle **/ (globstar: zero or more directories)
  defp build_regex_parts(["*", "*", "/" | rest], acc, _prev_star) do
    build_regex_parts(rest, ["(.+/)?" | acc], false)
  end

  # Handle ** at end of pattern (match everything)
  defp build_regex_parts(["*", "*"], acc, _prev_star) do
    build_regex_parts([], [".*" | acc], false)
  end

  # Handle * (match anything except /)
  defp build_regex_parts(["*" | rest], acc, _prev_star) do
    build_regex_parts(rest, ["[^/]*" | acc], true)
  end

  # Handle ? (match single char except /)
  defp build_regex_parts(["?" | rest], acc, _prev_star) do
    build_regex_parts(rest, ["[^/]" | acc], false)
  end

  # Handle . (escape for regex)
  defp build_regex_parts(["." | rest], acc, _prev_star) do
    build_regex_parts(rest, ["\\." | acc], false)
  end

  # Handle any other character
  defp build_regex_parts([char | rest], acc, _prev_star) do
    build_regex_parts(rest, [Regex.escape(char) | acc], false)
  end

  defp build_regex_parts([], acc, _prev_star), do: acc

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

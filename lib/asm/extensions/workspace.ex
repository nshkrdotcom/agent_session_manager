defmodule ASM.Extensions.Workspace do
  @moduledoc """
  Public workspace extension API.

  This domain provides workspace snapshot/diff/rollback primitives for
  host-managed run orchestration without coupling core runtime internals.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      ASM.Extensions.Workspace,
      ASM.Extensions.Workspace.Backend,
      ASM.Extensions.Workspace.Diff,
      ASM.Extensions.Workspace.GitBackend,
      ASM.Extensions.Workspace.HashBackend,
      ASM.Extensions.Workspace.Snapshot
    ]

  alias ASM.Error
  alias ASM.Extensions.Workspace.{Diff, GitBackend, HashBackend, Snapshot}

  @typedoc "Configured backend selection strategy."
  @type backend_kind :: :auto | :git | :hash

  @typedoc "Workspace snapshot operation result."
  @type snapshot_result :: {:ok, Snapshot.t()} | {:error, Error.t()}

  @typedoc "Workspace diff operation result."
  @type diff_result :: {:ok, Diff.t()} | {:error, Error.t()}

  @typedoc "Workspace rollback operation result."
  @type rollback_result :: :ok | {:error, Error.t()}

  @spec snapshot(String.t(), keyword()) :: snapshot_result()
  def snapshot(root, opts \\ []) when is_binary(root) and is_list(opts) do
    backend_kind = Keyword.get(opts, :backend, :auto)

    with {:ok, normalized_root} <- normalize_root(root),
         {:ok, backend_module} <- resolve_backend(backend_kind, normalized_root),
         {:ok, %Snapshot{} = snapshot} <-
           safe_backend_call(
             fn -> backend_module.snapshot(normalized_root, opts) end,
             "snapshot/2 failed"
           ) do
      {:ok, snapshot}
    end
  end

  @spec diff(Snapshot.t(), Snapshot.t(), keyword()) :: diff_result()
  def diff(%Snapshot{} = from_snapshot, %Snapshot{} = to_snapshot, opts \\ [])
      when is_list(opts) do
    with :ok <- validate_diff_inputs(from_snapshot, to_snapshot),
         {:ok, backend_module} <- backend_module(from_snapshot.backend),
         {:ok, %Diff{} = diff} <-
           safe_backend_call(
             fn -> backend_module.diff(from_snapshot, to_snapshot, opts) end,
             "diff/3 failed"
           ) do
      {:ok, diff}
    end
  end

  @spec rollback(Snapshot.t(), keyword()) :: rollback_result()
  def rollback(%Snapshot{} = snapshot, opts \\ []) when is_list(opts) do
    case backend_module(snapshot.backend) do
      {:ok, backend_module} ->
        safe_backend_call(
          fn -> backend_module.rollback(snapshot, opts) end,
          "rollback/2 failed"
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp normalize_root(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "workspace root does not exist or is not a directory: #{inspect(root)}"
       )}
    end
  end

  defp resolve_backend(:auto, root) do
    if GitBackend.available?(root), do: {:ok, GitBackend}, else: {:ok, HashBackend}
  end

  defp resolve_backend(:git, root) do
    if GitBackend.available?(root) do
      {:ok, GitBackend}
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "git backend requires a git repository root and a working git executable"
       )}
    end
  end

  defp resolve_backend(:hash, _root), do: {:ok, HashBackend}

  defp resolve_backend(other, _root) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "unsupported workspace backend: #{inspect(other)}"
     )}
  end

  defp backend_module(:git), do: {:ok, GitBackend}
  defp backend_module(:hash), do: {:ok, HashBackend}

  defp backend_module(other) do
    {:error,
     Error.new(
       :config_invalid,
       :config,
       "unsupported workspace snapshot backend: #{inspect(other)}"
     )}
  end

  defp validate_diff_inputs(%Snapshot{} = from_snapshot, %Snapshot{} = to_snapshot) do
    cond do
      from_snapshot.backend != to_snapshot.backend ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "workspace diff requires snapshots from the same backend"
         )}

      not same_path?(from_snapshot.root, to_snapshot.root) ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "workspace diff requires snapshots from the same root"
         )}

      true ->
        :ok
    end
  end

  defp safe_backend_call(fun, operation) when is_function(fun, 0) and is_binary(operation) do
    case fun.() do
      :ok ->
        :ok

      {:ok, value} ->
        {:ok, value}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error, Error.new(:unknown, :runtime, operation, cause: other)}
    end
  rescue
    error in [Error] ->
      {:error, error}

    error ->
      {:error, Error.new(:unknown, :runtime, operation, cause: error)}
  catch
    :exit, reason ->
      {:error, Error.new(:unknown, :runtime, operation, cause: reason)}
  end

  defp same_path?(left, right) do
    Path.expand(left) == Path.expand(right)
  end
end

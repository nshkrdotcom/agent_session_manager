defmodule Boundary.Checker do
  @moduledoc false

  defmodule Violation do
    @moduledoc false
    @enforce_keys [:file, :line, :module, :boundary, :referenced, :referenced_boundary, :message]
    defstruct [:file, :line, :module, :boundary, :referenced, :referenced_boundary, :message]

    @type t :: %__MODULE__{
            file: Path.t(),
            line: pos_integer(),
            module: module(),
            boundary: module(),
            referenced: module(),
            referenced_boundary: module(),
            message: String.t()
          }
  end

  @spec check_project() :: {:ok, map()} | {:error, [Violation.t()]}
  def check_project do
    paths = Mix.Project.config()[:elixirc_paths] || ["lib"]

    sources =
      paths
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.sort()
      |> Enum.map(fn path -> {path, File.read!(path)} end)

    check_sources(sources)
  end

  @spec check_sources([{Path.t(), String.t()}]) :: {:ok, map()} | {:error, [Violation.t()]}
  def check_sources(sources) when is_list(sources) do
    {boundaries, modules} = parse_sources(sources)
    violations = boundary_violations(modules, boundaries)

    if violations == [] do
      {:ok, %{boundaries: boundaries, modules: modules}}
    else
      {:error, violations}
    end
  end

  @spec violations_for_sources([{Path.t(), String.t()}]) :: [Violation.t()]
  def violations_for_sources(sources) when is_list(sources) do
    {boundaries, modules} = parse_sources(sources)
    boundary_violations(modules, boundaries)
  end

  @spec format_violation(Violation.t()) :: String.t()
  def format_violation(%Violation{} = violation) do
    "#{violation.file}:#{violation.line}: #{violation.message}"
  end

  @spec parse_sources([{Path.t(), String.t()}]) :: {map(), [map()]}
  def parse_sources(sources) when is_list(sources) do
    modules =
      sources
      |> Enum.flat_map(fn {path, source} -> parse_file(path, source) end)

    boundaries =
      modules
      |> Enum.reduce(%{}, fn module_info, acc ->
        case module_info.boundary_opts do
          nil ->
            acc

          opts ->
            Map.put(acc, module_info.module, %{
              module: module_info.module,
              deps: opts.deps,
              exports: opts.exports,
              file: module_info.file,
              line: module_info.line
            })
        end
      end)

    {boundaries, modules}
  end

  @spec boundary_violations([map()], map()) :: [Violation.t()]
  def boundary_violations(modules, boundaries) when is_list(modules) and is_map(boundaries) do
    boundary_modules = Map.keys(boundaries)

    modules
    |> Enum.flat_map(fn module_info ->
      owner = owner_boundary(module_info.module, boundary_modules)

      if is_nil(owner) do
        []
      else
        allowed = Map.get(boundaries, owner).deps

        module_info.refs
        |> Enum.flat_map(fn referenced ->
          referenced_owner = owner_boundary(referenced, boundary_modules)

          cond do
            is_nil(referenced_owner) ->
              []

            referenced_owner == owner ->
              []

            referenced_owner in allowed ->
              []

            true ->
              message =
                "#{inspect(module_info.module)} (#{inspect(owner)}) depends on " <>
                  "#{inspect(referenced)} (#{inspect(referenced_owner)}) without a declared boundary dependency"

              [
                %Violation{
                  file: module_info.file,
                  line: module_info.line,
                  module: module_info.module,
                  boundary: owner,
                  referenced: referenced,
                  referenced_boundary: referenced_owner,
                  message: message
                }
              ]
          end
        end)
      end
    end)
    |> Enum.uniq_by(fn violation ->
      {violation.file, violation.line, violation.module, violation.referenced}
    end)
  end

  defp parse_file(path, source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        collect_modules(path, ast)

      {:error, {line, error, token}} ->
        Mix.raise("boundary compiler failed to parse #{path}:#{line}: #{error} #{inspect(token)}")
    end
  end

  defp collect_modules(path, ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [name_ast, [do: body]]} = node, acc ->
          module = alias_to_module(name_ast)

          module_info = %{
            module: module,
            file: path,
            line: meta[:line] || 1,
            refs: collect_module_refs(body),
            boundary_opts: extract_boundary_opts(body)
          }

          {node, [module_info | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp extract_boundary_opts(body) do
    case find_boundary_use(body) do
      nil ->
        nil

      opts ->
        %{
          deps: opts |> Keyword.get(:deps, []) |> normalize_module_list(),
          exports: opts |> Keyword.get(:exports, []) |> normalize_module_list()
        }
    end
  end

  defp find_boundary_use(body) do
    body
    |> block_to_list()
    |> Enum.find_value(fn
      {:use, _, [boundary_ast]} ->
        if alias_to_module(boundary_ast) == Boundary, do: []

      {:use, _, [boundary_ast, opts]} when is_list(opts) ->
        if alias_to_module(boundary_ast) == Boundary, do: opts

      _ ->
        nil
    end)
  end

  defp collect_module_refs(ast) do
    {_ast, refs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__aliases__, _, parts} = node, acc ->
          {node, MapSet.put(acc, Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    refs
    |> MapSet.to_list()
    |> Enum.reject(&is_nil/1)
  end

  defp owner_boundary(module, boundary_modules) when is_atom(module) do
    boundary_modules
    |> Enum.filter(&module_prefix?(&1, module))
    |> Enum.max_by(&(Module.split(&1) |> length()), fn -> nil end)
  end

  defp module_prefix?(prefix, module) do
    prefix_parts = Module.split(prefix)
    module_parts = Module.split(module)
    Enum.take(module_parts, length(prefix_parts)) == prefix_parts
  end

  defp normalize_module_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_module/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_module_list(_other), do: []

  defp normalize_module({:__aliases__, _, parts}), do: Module.concat(parts)
  defp normalize_module(module) when is_atom(module), do: module
  defp normalize_module(_other), do: nil

  defp block_to_list({:__block__, _, exprs}) when is_list(exprs), do: exprs
  defp block_to_list(expr), do: [expr]

  defp alias_to_module({:__aliases__, _, parts}), do: Module.concat(parts)
  defp alias_to_module(module) when is_atom(module), do: module
  defp alias_to_module(_other), do: nil
end

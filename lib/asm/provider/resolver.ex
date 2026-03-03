defmodule ASM.Provider.Resolver do
  @moduledoc """
  Resolves provider CLI command execution path and argv prefix.

  Resolution order:

  1. Explicit `:cli_path` option
  2. Provider env var (e.g. `CLAUDE_CLI_PATH`)
  3. Provider binary names on `PATH`
  4. npm global bin lookup (when configured)
  5. npx fallback (when configured and not disabled)
  """

  alias ASM.Error
  alias ASM.Provider

  defmodule CommandSpec do
    @moduledoc """
    Resolved executable program and optional argv prefix for a provider CLI.
    """
    @enforce_keys [:program]
    defstruct program: "", argv_prefix: []

    @type t :: %__MODULE__{
            program: String.t(),
            argv_prefix: [String.t()]
          }
  end

  @type resolve_opt ::
          {:cli_path, String.t()}
          | {:env_getter, (String.t() -> String.t() | nil)}
          | {:env, (String.t() -> String.t() | nil)}
          | {:env, map()}
          | {:find_executable, (String.t() -> String.t() | nil)}
          | {:file_exists?, (String.t() -> boolean())}
          | {:executable?, (String.t() -> boolean())}
          | {:system_cmd, (String.t(), [String.t()] -> {String.t(), non_neg_integer()} | :error)}

  @type resolve_opts :: [resolve_opt()]

  @spec resolve(Provider.t() | Provider.provider_name(), resolve_opts()) ::
          {:ok, CommandSpec.t()} | {:error, Error.t()}
  def resolve(provider_or_name, opts \\ []) do
    with {:ok, provider} <- Provider.resolve(provider_or_name) do
      do_resolve(provider, opts)
    end
  end

  @spec resolve!(Provider.t() | Provider.provider_name(), resolve_opts()) :: CommandSpec.t()
  def resolve!(provider_or_name, opts \\ []) do
    case resolve(provider_or_name, opts) do
      {:ok, spec} ->
        spec

      {:error, %Error{} = error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @spec command_args(CommandSpec.t(), [String.t()]) :: [String.t()]
  def command_args(%CommandSpec{argv_prefix: prefix}, args) when is_list(args) do
    prefix ++ args
  end

  defp do_resolve(provider, opts) do
    case Keyword.get(opts, :cli_path) do
      path when is_binary(path) and path != "" ->
        validate_explicit_path(path, opts)

      _ ->
        resolve_by_fallback(provider, opts)
    end
  end

  defp resolve_by_fallback(provider, opts) do
    env = env_getter(opts)

    with {:miss, _env_path} <- from_env(provider, env, opts),
         :miss <- from_path(provider, find_executable(opts)),
         :miss <- from_npm_global(provider, opts),
         :miss <- from_npx(provider, opts) do
      {:error,
       Error.new(
         :cli_not_found,
         :provider,
         "Unable to resolve CLI for provider #{inspect(provider.name)}",
         provider: provider.name,
         cause: %{env_var: provider.env_var, binary_names: provider.binary_names}
       )}
    else
      {:ok, %CommandSpec{} = spec} ->
        {:ok, spec}

      {:invalid_env_path, path} ->
        {:error,
         Error.new(
           :cli_not_found,
           :provider,
           "Provider env path is invalid or not executable: #{path}",
           provider: provider.name,
           cause: %{env_var: provider.env_var, path: path}
         )}
    end
  end

  defp from_env(%Provider{env_var: nil}, _env, _opts), do: {:miss, nil}

  defp from_env(%Provider{} = provider, env_getter, opts) do
    file_exists = file_exists?(opts)
    executable = executable?(opts)

    case env_getter.(provider.env_var) do
      nil ->
        {:miss, nil}

      "" ->
        {:miss, nil}

      path ->
        case validate_path(path, file_exists, executable) do
          :ok -> {:ok, %CommandSpec{program: path}}
          :error -> {:invalid_env_path, path}
        end
    end
  end

  defp from_path(%Provider{binary_names: binary_names}, find_executable) do
    case Enum.find_value(binary_names, find_executable) do
      nil -> :miss
      program -> {:ok, %CommandSpec{program: program}}
    end
  end

  defp from_npm_global(%Provider{npm_package: nil}, _opts), do: :miss

  defp from_npm_global(%Provider{binary_names: [primary_binary | _]}, opts) do
    find_exec = find_executable(opts)
    file_exists = file_exists?(opts)
    executable = executable?(opts)
    system_cmd = system_cmd(opts)

    with npm when is_binary(npm) <- find_exec.("npm"),
         {prefix_output, 0} <- system_cmd.(npm, ["prefix", "-g"]),
         prefix <- String.trim(prefix_output),
         true <- prefix != "",
         candidate <- Path.join([prefix, "bin", primary_binary]),
         :ok <- validate_path(candidate, file_exists, executable) do
      {:ok, %CommandSpec{program: candidate}}
    else
      _ -> :miss
    end
  end

  defp from_npm_global(_provider, _opts), do: :miss

  defp from_npx(%Provider{npx_package: nil}, _opts), do: :miss

  defp from_npx(%Provider{binary_names: [primary_binary | _]} = provider, opts) do
    env_getter = env_getter(opts)
    find_exec = find_executable(opts)

    if npx_disabled?(provider, env_getter) do
      :miss
    else
      case find_exec.("npx") do
        nil ->
          :miss

        npx_path ->
          {:ok,
           %CommandSpec{
             program: npx_path,
             argv_prefix: ["--yes", "--package", provider.npx_package, primary_binary]
           }}
      end
    end
  end

  defp validate_explicit_path(path, opts) do
    case validate_path(path, file_exists?(opts), executable?(opts)) do
      :ok ->
        {:ok, %CommandSpec{program: path}}

      :error ->
        {:error,
         Error.new(
           :cli_not_found,
           :provider,
           "Explicit cli_path is invalid or not executable: #{path}",
           cause: %{path: path}
         )}
    end
  end

  defp validate_path(path, file_exists, executable) do
    if file_exists.(path) and executable.(path), do: :ok, else: :error
  end

  defp npx_disabled?(%Provider{disable_npx_env: nil}, _env_getter), do: false

  defp npx_disabled?(%Provider{disable_npx_env: env_var}, env_getter) do
    value =
      env_var
      |> env_getter.()
      |> normalize_env_flag()

    value in [true]
  end

  defp normalize_env_flag(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "1" -> true
      "true" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp normalize_env_flag(_), do: false

  defp env_getter(opts) do
    case Keyword.get(opts, :env_getter) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        env_opt = Keyword.get(opts, :env)

        cond do
          is_function(env_opt, 1) ->
            env_opt

          is_map(env_opt) ->
            map_env_getter(env_opt)

          true ->
            &System.get_env/1
        end
    end
  end

  defp find_executable(opts), do: Keyword.get(opts, :find_executable, &System.find_executable/1)
  defp file_exists?(opts), do: Keyword.get(opts, :file_exists?, &File.exists?/1)
  defp executable?(opts), do: Keyword.get(opts, :executable?, &default_executable?/1)

  defp system_cmd(opts) do
    Keyword.get(opts, :system_cmd, fn program, args ->
      System.cmd(program, args, stderr_to_stdout: true)
    end)
  end

  defp default_executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp map_env_getter(env_map) when is_map(env_map) do
    fn key ->
      case Map.fetch(env_map, key) do
        {:ok, value} ->
          value

        :error ->
          find_atom_key_value(env_map, key)
      end
    end
  end

  defp find_atom_key_value(env_map, key) do
    Enum.find_value(env_map, &atom_key_match(&1, key))
  end

  defp atom_key_match({k, value}, key) when is_atom(k) do
    case Atom.to_string(k) do
      ^key -> value
      _ -> nil
    end
  end

  defp atom_key_match(_entry, _key), do: nil
end

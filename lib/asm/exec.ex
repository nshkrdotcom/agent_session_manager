defmodule ASM.Exec do
  @moduledoc "Command building utilities for erlexec subprocess management."

  @spec build_argv(String.t(), [String.t()]) :: [charlist()]
  def build_argv(program, args) when is_binary(program) and is_list(args) do
    [program | args]
    |> Enum.map(&to_string/1)
    |> Enum.map(&to_charlist/1)
  end

  @spec add_cwd([term()], String.t() | nil) :: [term()]
  def add_cwd(opts, nil), do: opts
  def add_cwd(opts, cwd), do: [{:cd, to_charlist(cwd)} | opts]

  @spec add_env([term()], map() | keyword() | nil) :: [term()]
  def add_env(opts, nil), do: opts
  def add_env(opts, []), do: opts
  def add_env(opts, %{} = env), do: add_env(opts, Map.to_list(env))

  def add_env(opts, env) when is_list(env) do
    env_vars =
      Enum.map(env, fn {key, value} ->
        {to_charlist(to_string(key)), to_charlist(to_string(value))}
      end)

    [{:env, env_vars} | opts]
  end
end

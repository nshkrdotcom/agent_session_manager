defmodule ASM.Schema.RemoteNode do
  @moduledoc """
  Schema-backed parser for remote node execution configuration owned by ASM.
  """

  alias ASM.Schema
  alias CliSubprocessCore.Schema.Conventions

  @known_fields [
    :remote_node,
    :remote_cookie,
    :remote_connect_timeout_ms,
    :remote_rpc_timeout_ms,
    :remote_boot_lease_timeout_ms,
    :remote_bootstrap_mode,
    :remote_cwd
  ]

  @schema Zoi.map(
            %{
              remote_node: Zoi.any() |> Zoi.transform({__MODULE__, :normalize_remote_node, []}),
              remote_cookie:
                Zoi.optional(
                  Zoi.nullish(
                    Zoi.any()
                    |> Zoi.transform({__MODULE__, :normalize_remote_cookie, []})
                  )
                ),
              remote_connect_timeout_ms: Zoi.integer() |> Zoi.min(1),
              remote_rpc_timeout_ms: Zoi.integer() |> Zoi.min(1),
              remote_boot_lease_timeout_ms: Zoi.integer() |> Zoi.min(1),
              remote_bootstrap_mode: Conventions.enum([:require_prestarted, :ensure_started]),
              remote_cwd: Conventions.optional_trimmed_string()
            },
            unrecognized_keys: :preserve
          )

  @spec parse(keyword() | map()) ::
          {:ok, map()}
          | {:error, {:invalid_remote_node_config, CliSubprocessCore.Schema.error_detail()}}
  def parse(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Enum.into(attrs, %{})

    case Schema.parse(@schema, attrs, :invalid_remote_node_config) do
      {:ok, parsed} ->
        {known, extra} = Schema.split_extra(parsed, @known_fields)
        {:ok, Map.merge(known, extra)}

      {:error, {:invalid_remote_node_config, details}} ->
        {:error, {:invalid_remote_node_config, details}}
    end
  end

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  def normalize_remote_node(value, opts), do: normalize_remote_node(value, [], opts)

  @doc false
  def normalize_remote_node(value, _args, _opts) when is_atom(value) and not is_nil(value),
    do: {:ok, value}

  def normalize_remote_node(_value, _args, _opts) do
    {:error, "remote_node is required and must be an atom"}
  end

  @doc false
  def normalize_remote_cookie(value, opts), do: normalize_remote_cookie(value, [], opts)

  @doc false
  def normalize_remote_cookie(value, _args, _opts) when is_atom(value), do: {:ok, value}
  def normalize_remote_cookie(nil, _args, _opts), do: {:ok, nil}

  def normalize_remote_cookie(_value, _args, _opts) do
    {:error, "remote_cookie must be an atom"}
  end
end

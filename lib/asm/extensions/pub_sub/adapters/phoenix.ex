defmodule ASM.Extensions.PubSub.Adapters.Phoenix do
  @moduledoc """
  Phoenix PubSub adapter.

  This adapter is optional. If `phoenix_pubsub` is not available at compile/runtime,
  initialization returns a normalized `%ASM.Error{}`.
  """

  @behaviour ASM.Extensions.PubSub.Adapter

  alias ASM.Error

  @default_pubsub_module :"Elixir.Phoenix.PubSub"

  @type state :: %{name: atom(), pubsub_module: module()}

  @impl true
  def init(opts) when is_list(opts) do
    with {:ok, name} <- normalize_name(Keyword.get(opts, :name)),
         {:ok, pubsub_module} <- normalize_pubsub_module(Keyword.get(opts, :pubsub_module)),
         :ok <- ensure_pubsub_available(pubsub_module) do
      {:ok, %{name: name, pubsub_module: pubsub_module}}
    end
  end

  @impl true
  def broadcast(%{name: name, pubsub_module: pubsub_module}, topic, message)
      when is_binary(topic) do
    safe_apply(
      pubsub_module,
      :broadcast,
      [name, topic, message],
      "phoenix pubsub broadcast failed"
    )
  end

  @impl true
  def subscribe(%{name: name, pubsub_module: pubsub_module}, topic) when is_binary(topic) do
    safe_apply(pubsub_module, :subscribe, [name, topic], "phoenix pubsub subscribe failed")
  end

  defp safe_apply(module, function, args, message) do
    case apply(module, function, args) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, runtime_error(message, reason)}

      other ->
        {:error, runtime_error(message, {:unexpected_response, other})}
    end
  rescue
    error ->
      {:error, runtime_error(message, error)}
  catch
    :exit, reason ->
      {:error, runtime_error(message, reason)}
  end

  defp normalize_name(name) when is_atom(name), do: {:ok, name}

  defp normalize_name(nil) do
    {:error,
     config_error("phoenix adapter requires :name pubsub server (optional dependency config)")}
  end

  defp normalize_name(other) do
    {:error, config_error("phoenix adapter :name must be an atom, got: #{inspect(other)}")}
  end

  defp normalize_pubsub_module(nil), do: {:ok, @default_pubsub_module}
  defp normalize_pubsub_module(module) when is_atom(module), do: {:ok, module}

  defp normalize_pubsub_module(other) do
    {:error,
     config_error("phoenix adapter :pubsub_module must be a module atom, got: #{inspect(other)}")}
  end

  defp ensure_pubsub_available(pubsub_module) do
    cond do
      not Code.ensure_loaded?(pubsub_module) ->
        {:error, optional_dependency_error(pubsub_module)}

      not function_exported?(pubsub_module, :broadcast, 3) ->
        {:error,
         config_error("phoenix pubsub module #{inspect(pubsub_module)} must export broadcast/3")}

      not function_exported?(pubsub_module, :subscribe, 2) ->
        {:error,
         config_error("phoenix pubsub module #{inspect(pubsub_module)} must export subscribe/2")}

      true ->
        :ok
    end
  end

  defp optional_dependency_error(pubsub_module) do
    Error.new(
      :config_invalid,
      :config,
      "phoenix_pubsub optional dependency is not available: #{inspect(pubsub_module)}"
    )
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end

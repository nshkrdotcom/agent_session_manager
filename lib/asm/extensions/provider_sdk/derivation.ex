defmodule ASM.Extensions.ProviderSDK.Derivation do
  @moduledoc false

  alias ASM.{Error, Options}

  @spec strict_common(atom(), keyword()) ::
          {:ok, Options.preflight_result()} | {:error, Options.preflight_error() | Error.t()}
  def strict_common(provider, asm_common) when is_atom(provider) and is_list(asm_common) do
    Options.preflight(provider, asm_common, mode: :strict_common)
  end

  @spec ensure_native_override_boundary(keyword(), [atom()], String.t()) ::
          :ok | {:error, Error.t()}
  def ensure_native_override_boundary(native_overrides, asm_derived_keys, label)
      when is_list(native_overrides) and is_list(asm_derived_keys) do
    conflicts =
      native_overrides
      |> Keyword.keys()
      |> Enum.uniq()
      |> Enum.filter(&(&1 in asm_derived_keys))

    if conflicts == [] do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "#{label} native_overrides must not redefine ASM-derived options: " <>
           Enum.map_join(conflicts, ", ", &inspect/1) <>
           ". Set those fields in asm_common instead.",
         cause: conflicts
       )}
    end
  end

  @spec ensure_sdk_module(module(), String.t()) :: :ok | {:error, Error.t()}
  def ensure_sdk_module(module, label) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error,
       Error.new(
         :config_invalid,
         :provider,
         "#{label} is unavailable because the provider SDK is not loaded",
         cause: module
       )}
    end
  end

  @spec build_sdk_options(module(), keyword(), String.t()) ::
          {:ok, struct()} | {:error, Error.t()}
  def build_sdk_options(module, attrs, label) when is_atom(module) and is_list(attrs) do
    with :ok <- ensure_sdk_module(module, label) do
      options = struct(module, attrs)

      if function_exported?(module, :validate!, 1) do
        {:ok, module.validate!(options)}
      else
        {:ok, options}
      end
    end
  rescue
    error in [ArgumentError, KeyError] ->
      {:error,
       Error.new(
         :config_invalid,
         :config,
         "invalid #{label} SDK options: #{Exception.message(error)}",
         cause: error
       )}
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(attrs, _key, nil), do: attrs
  def maybe_put(attrs, key, value), do: Keyword.put(attrs, key, value)
end

defmodule ASM.Metadata do
  @moduledoc false

  @protected_atom_keys [
    :available_lanes,
    :backend,
    :capabilities,
    :core_profile_id,
    :default_lane,
    :execution_mode,
    :lane,
    :lane_fallback_reason,
    :lane_reason,
    :preferred_lane,
    :provider,
    :provider_display_name,
    :requested_lane,
    :sdk_available?,
    :sdk_runtime
  ]
  @protected_string_keys Enum.map(@protected_atom_keys, &Atom.to_string/1)

  @spec merge_run_metadata(map(), map()) :: map()
  def merge_run_metadata(authoritative, incoming)
      when is_map(authoritative) and is_map(incoming) do
    Map.merge(incoming, authoritative, fn key, incoming_value, authoritative_value ->
      if protected_key?(key) do
        authoritative_value
      else
        incoming_value
      end
    end)
  end

  def merge_run_metadata(authoritative, _incoming) when is_map(authoritative), do: authoritative

  defp protected_key?(key) when is_atom(key), do: key in @protected_atom_keys
  defp protected_key?(key) when is_binary(key), do: key in @protected_string_keys
  defp protected_key?(_key), do: false
end

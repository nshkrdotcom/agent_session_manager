defmodule ASM.InferenceEndpoint.Compatibility do
  @moduledoc false

  alias ASM.InferenceEndpoint.{BackendManifest, CompatibilityResult, ConsumerManifest}

  @spec resolve(BackendManifest.t(), ConsumerManifest.t(), map()) :: CompatibilityResult.t()
  def resolve(
        %BackendManifest{} = backend_manifest,
        %ConsumerManifest{} = consumer_manifest,
        request
      )
      when is_map(request) do
    runtime_kind = backend_manifest.runtime_kind

    management_mode =
      first_match(backend_manifest.management_modes, consumer_manifest.accepted_management_modes)

    protocol = first_match(backend_manifest.protocols, consumer_manifest.accepted_protocols)

    cond do
      runtime_kind not in consumer_manifest.accepted_runtime_kinds ->
        incompatible(:runtime_kind_mismatch, [:runtime_kind], backend_manifest, consumer_manifest)

      is_nil(management_mode) ->
        incompatible(
          :management_mode_mismatch,
          [:management_mode],
          backend_manifest,
          consumer_manifest
        )

      is_nil(protocol) ->
        incompatible(:unsupported_protocol, [:protocol], backend_manifest, consumer_manifest)

      capability_failure = request_capability_failure(backend_manifest, request) ->
        capability_failure

      capability_failure = required_capability_failure(backend_manifest, consumer_manifest) ->
        capability_failure

      true ->
        CompatibilityResult.new!(
          compatible?: true,
          reason: :protocol_match,
          resolved_runtime_kind: runtime_kind,
          resolved_management_mode: management_mode,
          resolved_protocol: protocol,
          warnings: capability_warnings(backend_manifest, consumer_manifest),
          metadata: compatibility_metadata(backend_manifest, consumer_manifest)
        )
    end
  end

  defp request_capability_failure(
         %BackendManifest{capabilities: capabilities} = backend_manifest,
         request
       ) do
    cond do
      request_stream?(request) and
          not capability_satisfied?(capability_value(capabilities, :streaming?), true) ->
        incompatible(
          :missing_streaming,
          [:streaming],
          backend_manifest,
          nil,
          %{requested_stream?: true}
        )

      request_uses_tools?(request) ->
        incompatible(
          :missing_capability,
          [:tool_calling],
          backend_manifest,
          nil,
          %{requested_tools?: true}
        )

      true ->
        nil
    end
  end

  defp required_capability_failure(
         %BackendManifest{} = backend_manifest,
         %ConsumerManifest{} = consumer_manifest
       ) do
    Enum.find_value(consumer_manifest.required_capabilities, fn {key, expected} ->
      actual = capability_value(backend_manifest.capabilities, key)

      cond do
        capability_satisfied?(actual, expected) ->
          nil

        key == :streaming? or key == "streaming?" ->
          incompatible(:missing_streaming, [:streaming], backend_manifest, consumer_manifest)

        true ->
          incompatible(
            :missing_capability,
            [normalize_requirement_key(key)],
            backend_manifest,
            consumer_manifest
          )
      end
    end)
  end

  defp capability_warnings(
         %BackendManifest{} = backend_manifest,
         %ConsumerManifest{} = consumer_manifest
       ) do
    Enum.reduce(consumer_manifest.optional_capabilities, [], fn {key, expected}, warnings ->
      actual = capability_value(backend_manifest.capabilities, key)

      if capability_satisfied?(actual, expected) do
        warnings
      else
        [normalize_requirement_key(key) | warnings]
      end
    end)
    |> Enum.reverse()
  end

  defp capability_satisfied?(actual, expected) when expected in [true, false],
    do: actual == expected

  defp capability_satisfied?(actual, :unknown), do: actual == :unknown
  defp capability_satisfied?(actual, expected), do: actual == expected

  defp normalize_requirement_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.trim_trailing("?")
    |> String.to_atom()
  end

  defp normalize_requirement_key(key) when is_binary(key) do
    key
    |> String.trim_trailing("?")
    |> String.to_atom()
  end

  defp normalize_requirement_key(_key), do: :capability

  defp capability_value(capabilities, key) when is_atom(key) do
    Map.get(capabilities, key, Map.get(capabilities, Atom.to_string(key)))
  end

  defp capability_value(capabilities, key) when is_binary(key) do
    Map.get(capabilities, key, Map.get(capabilities, String.to_atom(key)))
  rescue
    ArgumentError -> Map.get(capabilities, key)
  end

  defp capability_value(_capabilities, _key), do: nil

  defp request_stream?(request) do
    case value(request, :stream?, false) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp request_uses_tools?(request) do
    tool_policy = value(request, :tool_policy, %{})

    tools =
      value(tool_policy, :tools, value(request, :tools, []))

    tool_choice = value(request, :tool_choice)

    non_empty_list?(tools) or tool_choice not in [nil, :none, "none"]
  end

  defp non_empty_list?(value) when is_list(value), do: value != []
  defp non_empty_list?(_value), do: false

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp incompatible(
         reason,
         missing_requirements,
         backend_manifest,
         consumer_manifest,
         extra \\ %{}
       ) do
    CompatibilityResult.new!(
      compatible?: false,
      reason: reason,
      missing_requirements: missing_requirements,
      metadata: compatibility_metadata(backend_manifest, consumer_manifest) |> Map.merge(extra)
    )
  end

  defp compatibility_metadata(backend_manifest, consumer_manifest) do
    manifest_metadata =
      backend_manifest
      |> case do
        %BackendManifest{metadata: metadata} when is_map(metadata) -> Map.new(metadata)
        _other -> %{}
      end

    %{}
    |> maybe_put(:backend, backend_manifest.backend)
    |> maybe_put(:consumer, consumer_manifest && consumer_manifest.consumer)
    |> maybe_put(:provider, manifest_value(manifest_metadata, :provider))
    |> maybe_put(
      :published_capabilities,
      manifest_value(manifest_metadata, :published_capabilities)
    )
    |> maybe_put(:common_surface_only?, manifest_value(manifest_metadata, :common_surface_only?))
  end

  defp first_match(left, right) do
    Enum.find(left, &(&1 in right))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp manifest_value(metadata, key) when is_map(metadata) do
    case Map.fetch(metadata, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(metadata, Atom.to_string(key))
    end
  end
end

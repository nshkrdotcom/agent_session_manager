defmodule ASM.Phase6AdapterSelectionPolicyTest do
  use ASM.SerialTestCase

  alias ASM.{AdapterSelectionPolicy, ProviderRegistry}

  test "ASM provider registry declares its Phase 6 adapter selection policy" do
    policy = ProviderRegistry.adapter_selection_policy()
    dump = AdapterSelectionPolicy.dump(policy)

    assert policy.contract_version == "ExecutionPlane.AdapterSelectionPolicy.v1"
    assert policy.owner_repo == "agent_session_manager"
    assert policy.selection_surface == "provider_registry"
    assert policy.config_key == "cli_subprocess_core.provider_runtime_profiles"
    assert policy.default_value_when_unset == "normal_lane_resolution"

    assert policy.fail_closed_action_when_misconfigured ==
             "force_core_lane_or_reject_required_profile"

    assert_json_safe(dump)
    assert AdapterSelectionPolicy.new!(dump) == policy
  end

  test "ASM adapter policy rejects public simulation selectors" do
    assert_raise ArgumentError, ~r/public simulation selector/i, fn ->
      AdapterSelectionPolicy.new!(Map.put(adapter_policy_attrs(), :simulation, "service_mode"))
    end

    assert_raise ArgumentError, ~r/config_key.*public simulation selector/i, fn ->
      AdapterSelectionPolicy.new!(adapter_policy_attrs(%{config_key: "request.simulation"}))
    end
  end

  test "ASM rejects public simulation request keywords at provider resolution" do
    assert {:error, error} =
             ProviderRegistry.resolve(:codex, lane: :auto, simulation: :service_mode)

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.provider == :codex
    assert error.message =~ "public simulation selector"
  end

  defp adapter_policy_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        selection_surface: "provider_registry",
        owner_repo: "agent_session_manager",
        config_key: "cli_subprocess_core.provider_runtime_profiles",
        default_value_when_unset: "normal_lane_resolution",
        fail_closed_action_when_misconfigured: "force_core_lane_or_reject_required_profile"
      },
      overrides
    )
  end

  defp assert_json_safe(value) when is_binary(value) or is_boolean(value) or is_nil(value),
    do: :ok

  defp assert_json_safe(value) when is_integer(value) or is_float(value), do: :ok

  defp assert_json_safe(value) when is_list(value), do: Enum.each(value, &assert_json_safe/1)

  defp assert_json_safe(value) when is_map(value) do
    assert Enum.all?(Map.keys(value), &is_binary/1)
    Enum.each(value, fn {_key, nested} -> assert_json_safe(nested) end)
  end
end

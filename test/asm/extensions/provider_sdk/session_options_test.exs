defmodule ASM.Extensions.ProviderSDK.SessionOptionsTest do
  use ASM.TestCase

  alias ASM.Extensions.ProviderSDK.SessionOptions
  alias CliSubprocessCore.ExecutionSurface

  @execution_surface_contract_version ExecutionSurface.__struct__().contract_version

  test "extract_execution_surface/1 normalizes struct, keyword, and map inputs" do
    assert {:ok, %ExecutionSurface{} = from_keyword, [provider: :claude]} =
             SessionOptions.extract_execution_surface(
               provider: :claude,
               execution_surface: [
                 contract_version: @execution_surface_contract_version,
                 surface_kind: :ssh_exec,
                 transport_options: [destination: "keyword.example"],
                 target_id: "keyword-target"
               ]
             )

    assert from_keyword.surface_kind == :ssh_exec
    assert from_keyword.contract_version == @execution_surface_contract_version
    assert from_keyword.transport_options[:destination] == "keyword.example"
    assert from_keyword.target_id == "keyword-target"

    assert {:ok, %ExecutionSurface{} = from_map, []} =
             SessionOptions.extract_execution_surface(
               execution_surface: %{
                 "contract_version" => @execution_surface_contract_version,
                 "surface_kind" => :ssh_exec,
                 "transport_options" => [destination: "map.example"],
                 "lease_ref" => "lease-9"
               }
             )

    assert from_map.surface_kind == :ssh_exec
    assert from_map.contract_version == @execution_surface_contract_version
    assert from_map.transport_options[:destination] == "map.example"
    assert from_map.lease_ref == "lease-9"

    assert {:ok, %ExecutionSurface{} = from_struct, []} =
             SessionOptions.extract_execution_surface(
               execution_surface: %ExecutionSurface{
                 contract_version: @execution_surface_contract_version,
                 surface_kind: :ssh_exec,
                 transport_options: [destination: "struct.example"]
               }
             )

    assert from_struct.surface_kind == :ssh_exec
    assert from_struct.contract_version == @execution_surface_contract_version
    assert from_struct.transport_options[:destination] == "struct.example"
  end

  test "extract_execution_surface/1 rejects legacy split surface keys" do
    assert {:error, error} =
             SessionOptions.extract_execution_surface(
               surface_kind: :ssh_exec,
               transport_options: [destination: "legacy.example"]
             )

    assert error.kind == :config_invalid
    assert error.message =~ "legacy execution-surface keys"
    assert error.message =~ ":execution_surface"
  end
end

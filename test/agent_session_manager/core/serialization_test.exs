defmodule AgentSessionManager.Core.SerializationTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Serialization

  describe "atomize_keys/1" do
    test "converts only existing atom keys and preserves unknown keys as strings" do
      map = %{
        "status" => "running",
        "totally_new_key_12345" => "value",
        "nested" => %{"metadata" => %{"another_unknown" => true}}
      }

      atomized = Serialization.atomize_keys(map)

      assert atomized[:status] == "running"
      assert atomized["totally_new_key_12345"] == "value"
      assert atomized[:nested][:metadata]["another_unknown"] == true
    end
  end

  describe "stringify_keys/1" do
    test "recursively stringifies atom keys" do
      map = %{status: :running, nested: %{count: 1}}
      stringified = Serialization.stringify_keys(map)

      assert stringified["status"] == "running"
      assert stringified["nested"]["count"] == 1
    end
  end

  describe "has_key?/2" do
    test "matches either string or existing atom key forms" do
      map = %{status: :ok}

      assert Serialization.has_key?(map, "status")
      refute Serialization.has_key?(map, "missing")
    end
  end
end

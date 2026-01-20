defmodule AgentSessionManager.Core.RegistryTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.{Registry, Manifest, Capability}

  # Helper to create test manifests
  defp create_manifest(name, version, opts \\ []) do
    {:ok, manifest} =
      Manifest.new(%{
        name: name,
        version: version,
        provider: Keyword.get(opts, :provider, "test-provider"),
        description: Keyword.get(opts, :description),
        capabilities: Keyword.get(opts, :capabilities, [])
      })

    manifest
  end

  describe "Registry struct" do
    test "has required fields" do
      registry = %Registry{}

      assert Map.has_key?(registry, :manifests)
      assert Map.has_key?(registry, :metadata)
    end

    test "has default values" do
      registry = %Registry{}

      assert registry.manifests == %{}
      assert registry.metadata == %{}
    end
  end

  describe "Registry.new/0" do
    test "creates an empty registry" do
      registry = Registry.new()

      assert %Registry{} = registry
      assert registry.manifests == %{}
    end
  end

  describe "Registry.new/1" do
    test "creates registry with metadata" do
      registry = Registry.new(metadata: %{created_by: "test"})

      assert registry.metadata == %{created_by: "test"}
    end
  end

  describe "Registry.register/2" do
    test "registers a new manifest" do
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      {:ok, updated} = Registry.register(registry, manifest)

      assert Map.has_key?(updated.manifests, "my-agent")
      assert updated.manifests["my-agent"].name == "my-agent"
    end

    test "returns error when manifest with same name exists" do
      registry = Registry.new()
      manifest1 = create_manifest("my-agent", "1.0.0")
      manifest2 = create_manifest("my-agent", "2.0.0")

      {:ok, registry} = Registry.register(registry, manifest1)
      result = Registry.register(registry, manifest2)

      assert {:error, error} = result
      assert error.code == :already_exists
      assert error.message =~ "my-agent"
    end

    test "validates manifest before registering" do
      registry = Registry.new()
      # Invalid manifest (missing required fields)
      invalid = %Manifest{}

      result = Registry.register(registry, invalid)

      assert {:error, error} = result
      assert error.code == :validation_error
    end

    test "is deterministic - same inputs produce same outputs" do
      manifest = create_manifest("my-agent", "1.0.0")

      registry1 = Registry.new()
      {:ok, result1} = Registry.register(registry1, manifest)

      registry2 = Registry.new()
      {:ok, result2} = Registry.register(registry2, manifest)

      assert result1.manifests == result2.manifests
    end
  end

  describe "Registry.unregister/2" do
    test "removes a manifest by name" do
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      {:ok, registry} = Registry.register(registry, manifest)
      {:ok, updated} = Registry.unregister(registry, "my-agent")

      refute Map.has_key?(updated.manifests, "my-agent")
    end

    test "returns error when manifest not found" do
      registry = Registry.new()

      result = Registry.unregister(registry, "nonexistent")

      assert {:error, error} = result
      assert error.code == :not_found
    end
  end

  describe "Registry.get/2" do
    test "retrieves a manifest by name" do
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      {:ok, registry} = Registry.register(registry, manifest)
      {:ok, retrieved} = Registry.get(registry, "my-agent")

      assert retrieved.name == "my-agent"
      assert retrieved.version == "1.0.0"
    end

    test "returns error when manifest not found" do
      registry = Registry.new()

      result = Registry.get(registry, "nonexistent")

      assert {:error, error} = result
      assert error.code == :not_found
    end
  end

  describe "Registry.list/1" do
    test "returns all registered manifests" do
      registry = Registry.new()
      manifest1 = create_manifest("agent-1", "1.0.0")
      manifest2 = create_manifest("agent-2", "2.0.0")

      {:ok, registry} = Registry.register(registry, manifest1)
      {:ok, registry} = Registry.register(registry, manifest2)

      manifests = Registry.list(registry)

      assert length(manifests) == 2
      names = Enum.map(manifests, & &1.name)
      assert "agent-1" in names
      assert "agent-2" in names
    end

    test "returns empty list for empty registry" do
      registry = Registry.new()

      assert Registry.list(registry) == []
    end

    test "returns manifests in deterministic order" do
      registry = Registry.new()
      manifest1 = create_manifest("z-agent", "1.0.0")
      manifest2 = create_manifest("a-agent", "1.0.0")

      {:ok, registry} = Registry.register(registry, manifest1)
      {:ok, registry} = Registry.register(registry, manifest2)

      list1 = Registry.list(registry)
      list2 = Registry.list(registry)

      assert list1 == list2
    end
  end

  describe "Registry.exists?/2" do
    test "returns true when manifest exists" do
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      {:ok, registry} = Registry.register(registry, manifest)

      assert Registry.exists?(registry, "my-agent")
    end

    test "returns false when manifest does not exist" do
      registry = Registry.new()

      refute Registry.exists?(registry, "nonexistent")
    end
  end

  describe "Registry.count/1" do
    test "returns the number of registered manifests" do
      registry = Registry.new()
      manifest1 = create_manifest("agent-1", "1.0.0")
      manifest2 = create_manifest("agent-2", "2.0.0")

      assert Registry.count(registry) == 0

      {:ok, registry} = Registry.register(registry, manifest1)
      assert Registry.count(registry) == 1

      {:ok, registry} = Registry.register(registry, manifest2)
      assert Registry.count(registry) == 2
    end
  end

  describe "Registry.update/2" do
    test "updates an existing manifest" do
      registry = Registry.new()
      original = create_manifest("my-agent", "1.0.0", description: "Original")

      {:ok, registry} = Registry.register(registry, original)

      updated_manifest = create_manifest("my-agent", "1.1.0", description: "Updated")
      {:ok, registry} = Registry.update(registry, updated_manifest)

      {:ok, retrieved} = Registry.get(registry, "my-agent")
      assert retrieved.version == "1.1.0"
      assert retrieved.description == "Updated"
    end

    test "returns error when manifest does not exist" do
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      result = Registry.update(registry, manifest)

      assert {:error, error} = result
      assert error.code == :not_found
    end
  end

  describe "Registry.validate_manifest/1" do
    test "returns :ok for valid manifest" do
      manifest = create_manifest("my-agent", "1.0.0")

      assert :ok = Registry.validate_manifest(manifest)
    end

    test "returns error with helpful message for missing name" do
      invalid = %Manifest{version: "1.0.0"}

      result = Registry.validate_manifest(invalid)

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "name"
    end

    test "returns error with helpful message for missing version" do
      invalid = %Manifest{name: "my-agent"}

      result = Registry.validate_manifest(invalid)

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "version"
    end

    test "returns error with helpful message for invalid capability" do
      {:ok, manifest} =
        Manifest.new(%{
          name: "my-agent",
          version: "1.0.0"
        })

      # Manually inject an invalid capability
      invalid_cap = %Capability{name: "", type: nil}
      invalid = %{manifest | capabilities: [invalid_cap]}

      result = Registry.validate_manifest(invalid)

      assert {:error, error} = result
      assert error.code == :validation_error
      assert error.message =~ "capability" or error.message =~ "Capability"
    end
  end

  describe "Registry.filter_by_provider/2" do
    test "returns manifests matching the provider" do
      registry = Registry.new()
      manifest1 = create_manifest("agent-1", "1.0.0", provider: "anthropic")
      manifest2 = create_manifest("agent-2", "1.0.0", provider: "openai")
      manifest3 = create_manifest("agent-3", "1.0.0", provider: "anthropic")

      {:ok, registry} = Registry.register(registry, manifest1)
      {:ok, registry} = Registry.register(registry, manifest2)
      {:ok, registry} = Registry.register(registry, manifest3)

      anthropic_agents = Registry.filter_by_provider(registry, "anthropic")

      assert length(anthropic_agents) == 2
      assert Enum.all?(anthropic_agents, &(&1.provider == "anthropic"))
    end

    test "returns empty list when no manifests match" do
      registry = Registry.new()
      manifest = create_manifest("agent-1", "1.0.0", provider: "anthropic")

      {:ok, registry} = Registry.register(registry, manifest)

      result = Registry.filter_by_provider(registry, "openai")

      assert result == []
    end
  end

  describe "Registry.filter_by_capability/2" do
    test "returns manifests that have the specified capability type" do
      {:ok, tool_cap} = Capability.new(%{name: "search", type: :tool})
      {:ok, resource_cap} = Capability.new(%{name: "files", type: :resource})

      manifest1 = create_manifest("agent-1", "1.0.0", capabilities: [tool_cap])
      manifest2 = create_manifest("agent-2", "1.0.0", capabilities: [resource_cap])
      manifest3 = create_manifest("agent-3", "1.0.0", capabilities: [tool_cap, resource_cap])

      registry = Registry.new()
      {:ok, registry} = Registry.register(registry, manifest1)
      {:ok, registry} = Registry.register(registry, manifest2)
      {:ok, registry} = Registry.register(registry, manifest3)

      tool_agents = Registry.filter_by_capability(registry, :tool)

      assert length(tool_agents) == 2
      names = Enum.map(tool_agents, & &1.name)
      assert "agent-1" in names
      assert "agent-3" in names
    end

    test "returns empty list when no manifests have the capability" do
      manifest = create_manifest("agent-1", "1.0.0", capabilities: [])

      registry = Registry.new()
      {:ok, registry} = Registry.register(registry, manifest)

      result = Registry.filter_by_capability(registry, :sampling)

      assert result == []
    end
  end

  describe "thread-safety (concurrent operations)" do
    test "concurrent registrations don't lose data" do
      # While Elixir's immutable data structures are inherently thread-safe,
      # this test verifies the API design supports concurrent use patterns
      registry = Registry.new()

      manifests =
        for i <- 1..10 do
          create_manifest("agent-#{i}", "1.0.0")
        end

      # Simulate concurrent registration by reducing
      final_registry =
        Enum.reduce(manifests, registry, fn manifest, reg ->
          {:ok, updated} = Registry.register(reg, manifest)
          updated
        end)

      assert Registry.count(final_registry) == 10
    end

    test "registry operations are pure functions" do
      # Verify that registry operations don't mutate state
      registry = Registry.new()
      manifest = create_manifest("my-agent", "1.0.0")

      # Store original state
      original_manifests = registry.manifests

      # Perform operation
      {:ok, _updated} = Registry.register(registry, manifest)

      # Original should be unchanged
      assert registry.manifests == original_manifests
    end
  end

  describe "Registry.to_map/1 and Registry.from_map/1" do
    test "serializes and deserializes registry" do
      registry = Registry.new(metadata: %{version: "1.0"})
      manifest = create_manifest("my-agent", "1.0.0")

      {:ok, registry} = Registry.register(registry, manifest)

      map = Registry.to_map(registry)
      {:ok, restored} = Registry.from_map(map)

      assert Registry.count(restored) == 1
      {:ok, retrieved} = Registry.get(restored, "my-agent")
      assert retrieved.name == "my-agent"
    end

    test "handles empty registry" do
      registry = Registry.new()

      map = Registry.to_map(registry)
      {:ok, restored} = Registry.from_map(map)

      assert Registry.count(restored) == 0
    end

    test "returns error for invalid map" do
      result = Registry.from_map("not a map")

      assert {:error, error} = result
      assert error.code == :validation_error
    end
  end
end

defmodule AgentSessionManager.Core.CapabilityResolverTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.{CapabilityResolver, Capability}

  # Helper to create test capabilities
  defp create_capability(name, type, opts \\ []) do
    {:ok, cap} =
      Capability.new(%{
        name: name,
        type: type,
        enabled: Keyword.get(opts, :enabled, true),
        description: Keyword.get(opts, :description)
      })

    cap
  end

  describe "CapabilityResolver struct" do
    test "has required fields" do
      resolver = %CapabilityResolver{}

      assert Map.has_key?(resolver, :required)
      assert Map.has_key?(resolver, :optional)
    end

    test "has default empty sets" do
      resolver = %CapabilityResolver{}

      assert resolver.required == MapSet.new()
      assert resolver.optional == MapSet.new()
    end
  end

  describe "CapabilityResolver.new/1" do
    test "creates resolver with required capabilities" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool, :resource])

      assert MapSet.member?(resolver.required, :tool)
      assert MapSet.member?(resolver.required, :resource)
    end

    test "creates resolver with optional capabilities" do
      {:ok, resolver} = CapabilityResolver.new(optional: [:sampling, :prompt])

      assert MapSet.member?(resolver.optional, :sampling)
      assert MapSet.member?(resolver.optional, :prompt)
    end

    test "creates resolver with both required and optional" do
      {:ok, resolver} =
        CapabilityResolver.new(
          required: [:tool],
          optional: [:sampling]
        )

      assert MapSet.member?(resolver.required, :tool)
      assert MapSet.member?(resolver.optional, :sampling)
    end

    test "accepts empty lists" do
      {:ok, resolver} = CapabilityResolver.new(required: [], optional: [])

      assert MapSet.size(resolver.required) == 0
      assert MapSet.size(resolver.optional) == 0
    end

    test "creates resolver with no arguments" do
      {:ok, resolver} = CapabilityResolver.new([])

      assert resolver.required == MapSet.new()
      assert resolver.optional == MapSet.new()
    end

    test "returns error for invalid capability type in required" do
      result = CapabilityResolver.new(required: [:invalid_type])

      assert {:error, error} = result
      assert error.code == :invalid_capability_type
    end

    test "returns error for invalid capability type in optional" do
      result = CapabilityResolver.new(optional: [:invalid_type])

      assert {:error, error} = result
      assert error.code == :invalid_capability_type
    end

    test "handles capability name strings converted to atoms" do
      {:ok, resolver} = CapabilityResolver.new(required: ["tool", "resource"])

      assert MapSet.member?(resolver.required, :tool)
      assert MapSet.member?(resolver.required, :resource)
    end
  end

  describe "CapabilityResolver.negotiate/2" do
    test "returns supported capabilities when all required are present" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool, :resource])

      provider_capabilities = [
        create_capability("web_search", :tool),
        create_capability("file_access", :resource),
        create_capability("code_runner", :code_execution)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert MapSet.member?(result.supported, :tool)
      assert MapSet.member?(result.supported, :resource)
      assert result.unsupported == MapSet.new()
      assert result.warnings == []
    end

    test "fails fast when required capability is missing" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool, :sampling])

      provider_capabilities = [
        create_capability("web_search", :tool)
        # Missing :sampling capability
      ]

      result = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert {:error, error} = result
      assert error.code == :missing_required_capability
      assert error.message =~ "sampling"
    end

    test "surfaces optional capability failures as warnings" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool], optional: [:sampling, :prompt])

      provider_capabilities = [
        create_capability("web_search", :tool),
        create_capability("template", :prompt)
        # Missing :sampling (optional)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert MapSet.member?(result.supported, :tool)
      assert MapSet.member?(result.supported, :prompt)
      assert MapSet.member?(result.unsupported, :sampling)
      assert length(result.warnings) == 1
      assert hd(result.warnings) =~ "sampling"
    end

    test "returns degraded status when optional capabilities are missing" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool], optional: [:sampling])

      provider_capabilities = [
        create_capability("web_search", :tool)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert result.status == :degraded
      assert MapSet.member?(result.unsupported, :sampling)
    end

    test "returns full status when all capabilities are satisfied" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool], optional: [:resource])

      provider_capabilities = [
        create_capability("web_search", :tool),
        create_capability("file_access", :resource)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert result.status == :full
      assert result.unsupported == MapSet.new()
      assert result.warnings == []
    end

    test "handles multiple missing required capabilities" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool, :resource, :sampling])

      provider_capabilities = [
        create_capability("web_search", :tool)
        # Missing :resource and :sampling
      ]

      result = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert {:error, error} = result
      assert error.code == :missing_required_capability
      # Should mention at least one missing capability
      assert error.message =~ "resource" or error.message =~ "sampling"
    end

    test "handles empty provider capabilities" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool])

      result = CapabilityResolver.negotiate(resolver, [])

      assert {:error, error} = result
      assert error.code == :missing_required_capability
    end

    test "handles empty requirements" do
      {:ok, resolver} = CapabilityResolver.new([])

      provider_capabilities = [
        create_capability("web_search", :tool)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert result.status == :full
      assert result.supported == MapSet.new()
    end

    test "only considers enabled capabilities" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool])

      provider_capabilities = [
        create_capability("web_search", :tool, enabled: false)
      ]

      result = CapabilityResolver.negotiate(resolver, provider_capabilities)

      assert {:error, error} = result
      assert error.code == :missing_required_capability
    end

    test "counts each capability type only once regardless of multiple instances" do
      {:ok, resolver} = CapabilityResolver.new(required: [:tool])

      provider_capabilities = [
        create_capability("web_search", :tool),
        create_capability("code_runner", :tool),
        create_capability("math_solver", :tool)
      ]

      {:ok, result} = CapabilityResolver.negotiate(resolver, provider_capabilities)

      # :tool should only appear once in supported
      assert MapSet.size(result.supported) == 1
      assert MapSet.member?(result.supported, :tool)
    end
  end

  describe "CapabilityResolver.NegotiationResult struct" do
    test "has expected fields" do
      result = %CapabilityResolver.NegotiationResult{}

      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :supported)
      assert Map.has_key?(result, :unsupported)
      assert Map.has_key?(result, :warnings)
    end

    test "has default values" do
      result = %CapabilityResolver.NegotiationResult{}

      assert result.status == :unknown
      assert result.supported == MapSet.new()
      assert result.unsupported == MapSet.new()
      assert result.warnings == []
    end
  end

  describe "CapabilityResolver.capabilities_of_type/2" do
    test "filters capabilities by type" do
      capabilities = [
        create_capability("web_search", :tool),
        create_capability("code_runner", :tool),
        create_capability("file_access", :resource)
      ]

      tools = CapabilityResolver.capabilities_of_type(capabilities, :tool)

      assert length(tools) == 2
      assert Enum.all?(tools, &(&1.type == :tool))
    end

    test "returns empty list when no capabilities match" do
      capabilities = [
        create_capability("web_search", :tool)
      ]

      result = CapabilityResolver.capabilities_of_type(capabilities, :sampling)

      assert result == []
    end
  end

  describe "CapabilityResolver.has_capability_type?/2" do
    test "returns true when capability type is present" do
      capabilities = [
        create_capability("web_search", :tool),
        create_capability("file_access", :resource)
      ]

      assert CapabilityResolver.has_capability_type?(capabilities, :tool)
      assert CapabilityResolver.has_capability_type?(capabilities, :resource)
    end

    test "returns false when capability type is not present" do
      capabilities = [
        create_capability("web_search", :tool)
      ]

      refute CapabilityResolver.has_capability_type?(capabilities, :sampling)
    end

    test "returns false for disabled capabilities" do
      capabilities = [
        create_capability("web_search", :tool, enabled: false)
      ]

      refute CapabilityResolver.has_capability_type?(capabilities, :tool)
    end

    test "returns false for empty list" do
      refute CapabilityResolver.has_capability_type?([], :tool)
    end
  end
end

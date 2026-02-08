defmodule AgentSessionManager.Routing.CapabilityMatcher do
  @moduledoc """
  Matches provider capabilities against routing requirements.

  Requirements support either:

  - `%{type: :tool, name: "bash"}` (type + name)
  - `%{type: :tool, name: nil}` (type-only)
  - `:tool` (type-only shorthand)
  """

  alias AgentSessionManager.Core.Capability

  @type requirement ::
          %{required(:type) => Capability.capability_type(), optional(:name) => String.t() | nil}
          | Capability.capability_type()

  @spec matches_all?([Capability.t()], [requirement()]) :: boolean()
  def matches_all?(capabilities, requirements)
      when is_list(capabilities) and is_list(requirements) do
    Enum.all?(requirements, fn requirement ->
      matches_requirement?(capabilities, requirement)
    end)
  end

  def matches_all?(_capabilities, _requirements), do: false

  @spec matches_requirement?([Capability.t()], requirement()) :: boolean()
  def matches_requirement?(capabilities, requirement) when is_list(capabilities) do
    normalized_requirement = normalize_requirement(requirement)

    Enum.any?(capabilities, fn
      %Capability{} = capability ->
        capability.enabled and capability_matches?(capability, normalized_requirement)

      _ ->
        false
    end)
  end

  defp normalize_requirement(%{type: type} = requirement) when is_atom(type) do
    %{type: type, name: Map.get(requirement, :name)}
  end

  defp normalize_requirement(type) when is_atom(type) do
    %{type: type, name: nil}
  end

  defp normalize_requirement(_invalid) do
    %{type: :unknown, name: nil}
  end

  defp capability_matches?(%Capability{type: capability_type, name: capability_name}, %{
         type: required_type,
         name: nil
       }) do
    capability_type == required_type and is_binary(capability_name)
  end

  defp capability_matches?(%Capability{type: capability_type, name: capability_name}, %{
         type: required_type,
         name: required_name
       })
       when is_binary(required_name) do
    capability_type == required_type and capability_name == required_name
  end

  defp capability_matches?(_capability, _requirement), do: false
end

defmodule ASM.SessionControlTest do
  use ASM.TestCase

  alias ASM.SessionControl

  test "builds a stable lineage descriptor from session info" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, descriptor} =
             SessionControl.lineage_descriptor(server,
               semantic_session_id: "semantic-1",
               boundary_session_id: "boundary-1",
               route_id: "route-1",
               attach_grant_id: "grant-1",
               provider_session_id: "provider-1"
             )

    assert SessionControl.lineage_keys() == [
             :semantic_session_id,
             :session_id,
             :lane_session_id,
             :provider_session_id,
             :boundary_session_id,
             :route_id,
             :attach_grant_id,
             :provider,
             :status
           ]

    assert descriptor == %{
             semantic_session_id: "semantic-1",
             session_id: session_id,
             lane_session_id: session_id,
             provider_session_id: "provider-1",
             boundary_session_id: "boundary-1",
             route_id: "route-1",
             attach_grant_id: "grant-1",
             provider: :claude,
             status: :ready
           }
  end

  test "normalizes provider pressure and reconnect facts" do
    assert SessionControl.provider_fact(:pressure, %{
             session_id: "asm-1",
             lane_session_id: "lane-1",
             provider_session_id: "provider-1",
             provider: :codex,
             reason: :rate_limited,
             observed_at: "2026-04-11T00:00:00Z",
             metadata: %{"queue_depth" => 3}
           }) == %{
             fact_kind: :pressure,
             session_id: "asm-1",
             lane_session_id: "lane-1",
             provider_session_id: "provider-1",
             provider: :codex,
             reason: :rate_limited,
             observed_at: "2026-04-11T00:00:00Z",
             metadata: %{"queue_depth" => 3}
           }

    assert SessionControl.provider_fact(:reconnect, %{
             session_id: "asm-1",
             provider: "claude"
           }).provider == :claude

    assert SessionControl.provider_fact(:reconnect, %{
             session_id: "asm-1",
             provider: "unbounded"
           }).provider == nil
  end

  defp start_session!(opts) when is_list(opts) do
    session_id = "asm-lineage-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, session} = ASM.start_session(Keyword.put(opts, :session_id, session_id))
    %{server: session, session_id: session_id}
  end
end

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ClusterRedirectTest do
  @moduledoc """
  MOVED / ASK handling of `HotKV.Cluster` against scripted fake nodes (no
  real cluster is involved; see test/support/fake_server.ex).
  """
  use ExUnit.Case, async: true

  alias HotKV.{Cluster, CRC16}
  alias HotKV.TestSupport.FakeServer, as: S

  @key "foo"

  defp slots_reply(owner_port) do
    S.array([
      S.array([S.int(0), S.int(16383), S.array([S.bulk("127.0.0.1"), S.int(owner_port)])])
    ])
  end

  test "the key hashes to the slot the fake nodes report" do
    # the redirect error lines below hard-code this slot
    assert CRC16.key_slot(@key) == 12182
  end

  test "MOVED refreshes the slot map and retries on the new owner" do
    {:ok, owner} = Agent.start_link(fn -> :a end)
    ports = Agent.start_link(fn -> %{} end) |> elem(1)

    {port_b, _} =
      S.start(fn
        ["GET", @key] -> S.bulk("from-b")
        ["CLUSTER", "SLOTS"] -> slots_reply(Agent.get(ports, & &1.b))
        _ -> nil
      end)

    {port_a, _} =
      S.start(fn
        ["GET", @key] ->
          Agent.update(owner, fn _ -> :b end)
          S.error("MOVED 12182 127.0.0.1:#{port_b}")

        ["CLUSTER", "SLOTS"] ->
          slots_reply(if Agent.get(owner, & &1) == :a, do: port_a_value(ports), else: port_b)

        _ ->
          nil
      end)

    Agent.update(ports, fn _ -> %{a: port_a, b: port_b} end)

    {:ok, cluster} = Cluster.start_link(seeds: ["127.0.0.1:#{port_a}"])
    assert {:ok, "from-b"} = Cluster.command(cluster, ["GET", @key])
    assert [%{master: {"127.0.0.1", ^port_b}}] = Cluster.slot_map(cluster)
  end

  defp port_a_value(ports), do: Agent.get(ports, & &1.a)

  test "ASK sends ASKING to the target node first, without changing the slot map" do
    test_pid = self()

    {port_b, _} =
      S.start(fn
        ["ASKING"] ->
          send(test_pid, :asking)
          S.simple("OK")

        ["GET", @key] ->
          send(test_pid, :get_on_b)
          S.bulk("from-b")

        _ ->
          nil
      end)

    ports = Agent.start_link(fn -> nil end) |> elem(1)

    {port_a, _} =
      S.start(fn
        ["GET", @key] -> S.error("ASK 12182 127.0.0.1:#{port_b}")
        ["CLUSTER", "SLOTS"] -> slots_reply(Agent.get(ports, & &1))
        _ -> nil
      end)

    Agent.update(ports, fn _ -> port_a end)

    {:ok, cluster} = Cluster.start_link(seeds: ["127.0.0.1:#{port_a}"])
    assert {:ok, "from-b"} = Cluster.command(cluster, ["GET", @key])
    assert_received :asking
    assert_received :get_on_b
    assert [%{master: {"127.0.0.1", ^port_a}}] = Cluster.slot_map(cluster)
  end

  test "redirects are followed at most :max_redirects times, then the redirect error is returned" do
    ports = Agent.start_link(fn -> nil end) |> elem(1)

    {port_a, _} =
      S.start(fn
        ["GET", @key] -> S.error("MOVED 12182 127.0.0.1:#{Agent.get(ports, & &1)}")
        ["CLUSTER", "SLOTS"] -> slots_reply(Agent.get(ports, & &1))
        _ -> nil
      end)

    Agent.update(ports, fn _ -> port_a end)

    {:ok, cluster} = Cluster.start_link(seeds: ["127.0.0.1:#{port_a}"])

    assert {:error, %HotKV.Error{kind: :cluster_redirect}} =
             Cluster.command(cluster, ["GET", @key], max_redirects: 3)
  end
end

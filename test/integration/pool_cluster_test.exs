# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PoolClusterIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Cluster, Pool, TestSupport}

  describe "Pool" do
    test "round-robins across its connections and commands work through it" do
      {:ok, pool} = Pool.start_link(url: TestSupport.test_url(), size: 3)
      assert %Pool{} = pool
      assert HotKV.connected?(pool)

      members = Pool.members(pool)
      assert length(members) == 3

      seen =
        for _ <- 1..6 do
          {:ok, pid} = Pool.checkout(pool)
          pid
        end

      # round-robin over 3 members, 6 checkouts: each member seen exactly twice
      assert seen |> Enum.frequencies() |> Map.values() |> Enum.sort() == [2, 2, 2]

      key = TestSupport.unique("pool")
      assert {:ok, "OK"} = HotKV.command(pool, ["SET", key, "v"])
      assert {:ok, "v"} = HotKV.command(pool, ["GET", key])
      HotKV.command(pool, ["DEL", key])

      Pool.stop(pool)
    end

    test "transaction/3 pins a single connection from the pool for the whole transaction" do
      {:ok, pool} = Pool.start_link(url: TestSupport.test_url(), size: 5)
      key = TestSupport.unique("pooltx")

      assert {:ok, ["OK", 1]} =
               HotKV.transaction(pool, fn conn ->
                 HotKV.command(conn, ["SET", key, "0"])
                 HotKV.command(conn, ["INCR", key])
               end)

      HotKV.command(pool, ["DEL", key])
      Pool.stop(pool)
    end
  end

  describe "Cluster" do
    test "routes commands by key slot, and reports a clear error when no node owns a slot yet" do
      {:ok, cluster} = Cluster.start_link(seeds: [seed_addr()])
      assert is_list(Cluster.slot_map(cluster))

      # The test server runs standalone (CLUSTER SLOTS reports no assigned
      # slots), so routing correctly cannot find an owning node; this is the
      # expected, well-typed outcome to exercise here rather than a real
      # multi-node MOVED/ASK redirect, which needs an actual cluster.
      assert {:error, %HotKV.Error{kind: :connection}} = Cluster.command(cluster, ["GET", "foo"])
    end

    test "host:port seed parsing" do
      assert HotKV.Cluster.__parse_host_port__("127.0.0.1:6399") == {"127.0.0.1", 6399}
      assert HotKV.Cluster.__parse_host_port__("host") == {"host", 6379}
    end
  end

  defp seed_addr do
    uri = URI.parse(TestSupport.test_url())
    "#{uri.host}:#{uri.port}"
  end
end

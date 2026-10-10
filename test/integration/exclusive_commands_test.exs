# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.ExclusiveCommandsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Gcra, HotKeys, NanoTTL, Tag, TestSupport, Vsim}

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  describe "HotKV.Tag (TAG.*, core)" do
    test "SET/GET/REM/COUNT/EXISTS/MEMBERS/INTER", %{conn: conn} do
      k = TestSupport.unique("tag:k")
      k2 = TestSupport.unique("tag:k2")
      on_exit(fn -> HotKV.command(conn, ["DEL", k, k2]) end)

      HotKV.command(conn, ["SET", k, "v"])
      HotKV.command(conn, ["SET", k2, "v"])

      assert {:ok, 2} = Tag.set(conn, k, ["hot", "warm"])
      assert {:ok, 1} = Tag.set(conn, k2, ["hot"])
      assert {:ok, tags} = Tag.get(conn, k)
      assert Enum.sort(tags) == ["hot", "warm"]
      assert {:ok, 2} = Tag.count(conn, k)
      assert {:ok, true} = Tag.exists?(conn, k, "hot")
      assert {:ok, false} = Tag.exists?(conn, k, "cold")

      assert {:ok, members} = Tag.members(conn, "hot")
      assert k in members
      assert k2 in members

      assert {:ok, inter} = Tag.inter(conn, ["hot", "warm"])
      assert k in inter
      refute k2 in inter
      assert {:ok, 1} = Tag.rem(conn, k, "warm")
    end

    test "TAG.SET on a missing key is a server error", %{conn: conn} do
      assert {:error, %HotKV.Error{kind: :server}} =
               Tag.set(conn, TestSupport.unique("tag:missing"), "x")
    end
  end

  describe "HotKV.NanoTTL (NEXPIRE/NTTL/NEXPIREAT, core)" do
    test "nanosecond-resolution TTL", %{conn: conn} do
      k = TestSupport.unique("nano")
      on_exit(fn -> HotKV.command(conn, ["DEL", k]) end)
      HotKV.command(conn, ["SET", k, "v"])

      assert {:ok, true} = NanoTTL.nexpire(conn, k, 5_000_000_000)
      assert {:ok, ns} = NanoTTL.nttl(conn, k)
      assert ns > 0

      assert {:ok, -2} = NanoTTL.nttl(conn, TestSupport.unique("nano:missing"))

      future_ns = System.os_time(:nanosecond) + 5_000_000_000
      assert {:ok, true} = NanoTTL.nexpireat(conn, k, future_ns)
    end
  end

  describe "HotKV.HotKeys (core, admin)" do
    test "TOP and RESET", %{conn: conn} do
      assert {:ok, "OK"} = HotKeys.reset(conn)
      assert {:ok, top} = HotKeys.top(conn)
      assert is_list(top)
      assert {:ok, top5} = HotKeys.top(conn, 5)
      assert length(top5) <= 5
    end
  end

  describe "HotKV.Gcra (core)" do
    test "LIMIT and RESET", %{conn: conn} do
      key = TestSupport.unique("gcra")

      assert {:ok, %{denied: false, limit: 2, remaining: remaining}} =
               Gcra.limit(conn, key, 1000, 2)

      assert remaining in [0, 1]
      assert {:ok, %{}} = Gcra.limit(conn, key, 1000, 2)
      assert {:ok, %{denied: true}} = Gcra.limit(conn, key, 1000, 2)
      assert {:ok, 1} = Gcra.reset(conn, key)
    end
  end

  describe "HotKV.Vsim (core except persistence)" do
    test "CREATEINDEX/SET/GET/SEARCH/DEL/INFO/DROPINDEX", %{conn: conn} do
      index = TestSupport.unique("vsim")
      assert {:ok, "OK"} = Vsim.createindex(conn, index, 3, metric: :cosine)

      assert {:ok, true} = Vsim.set(conn, index, "a", [1.0, 0.0, 0.0])
      assert {:ok, true} = Vsim.set(conn, index, "b", [0.0, 1.0, 0.0])
      assert {:ok, false} = Vsim.set(conn, index, "a", [1.0, 0.1, 0.0])

      assert {:ok, [v1, v2, v3]} = Vsim.get(conn, index, "a")
      assert_in_delta v1, 1.0, 0.01
      assert is_float(v2) and is_float(v3)

      assert {:ok, results} = Vsim.search(conn, index, 2, [1.0, 0.0, 0.0])
      assert [{"a", _distance} | _] = results

      assert {:ok, names} = Vsim.info(conn)
      assert index in names

      assert {:ok, %{"name" => ^index, "dimensions" => 3}} = Vsim.info(conn, index)

      assert {:ok, true} = Vsim.del(conn, index, "b")
      assert {:ok, "OK"} = Vsim.dropindex(conn, index)
    end
  end
end

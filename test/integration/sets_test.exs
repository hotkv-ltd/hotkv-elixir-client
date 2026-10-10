# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.SetsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Sets, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("set")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2", k <> ":dest"]) end)
    {:ok, conn: conn, k: k}
  end

  test "SADD/SREM/SMEMBERS/SISMEMBER/SMISMEMBER/SCARD", %{conn: conn, k: k} do
    assert {:ok, 3} = Sets.sadd(conn, k, ["a", "b", "c"])
    assert {:ok, 0} = Sets.sadd(conn, k, "a")
    assert {:ok, %MapSet{}} = Sets.smembers(conn, k)
    assert {:ok, members} = Sets.smembers(conn, k)
    assert MapSet.equal?(members, MapSet.new(["a", "b", "c"]))
    assert {:ok, true} = Sets.sismember(conn, k, "a")
    assert {:ok, false} = Sets.sismember(conn, k, "z")
    assert {:ok, [true, false]} = Sets.smismember(conn, k, ["a", "z"])
    assert {:ok, 3} = Sets.scard(conn, k)
    assert {:ok, 1} = Sets.srem(conn, k, "a")
    assert {:ok, 2} = Sets.scard(conn, k)
  end

  test "SPOP and SRANDMEMBER", %{conn: conn, k: k} do
    Sets.sadd(conn, k, ["a", "b", "c"])
    assert {:ok, popped} = Sets.spop(conn, k)
    assert popped in ["a", "b", "c"]
    assert {:ok, rest} = Sets.spop(conn, k, 2)
    assert length(rest) == 2
    assert {:ok, []} = Sets.spop(conn, k, 5)

    Sets.sadd(conn, k, ["x", "y"])
    assert {:ok, one} = Sets.srandmember(conn, k)
    assert one in ["x", "y"]
    assert {:ok, many} = Sets.srandmember(conn, k, 10)
    assert length(many) == 2
  end

  test "SUNION/SINTER/SDIFF and their *STORE variants, plus SINTERCARD", %{conn: conn, k: k} do
    k2 = k <> ":2"
    dest = k <> ":dest"
    Sets.sadd(conn, k, ["a", "b", "c"])
    Sets.sadd(conn, k2, ["b", "c", "d"])

    assert {:ok, union} = Sets.sunion(conn, [k, k2])
    assert MapSet.equal?(union, MapSet.new(["a", "b", "c", "d"]))

    assert {:ok, inter} = Sets.sinter(conn, [k, k2])
    assert MapSet.equal?(inter, MapSet.new(["b", "c"]))

    assert {:ok, diff} = Sets.sdiff(conn, [k, k2])
    assert MapSet.equal?(diff, MapSet.new(["a"]))

    assert {:ok, 4} = Sets.sunionstore(conn, dest, [k, k2])
    assert {:ok, 2} = Sets.sinterstore(conn, dest, [k, k2])
    assert {:ok, 1} = Sets.sdiffstore(conn, dest, [k, k2])
    assert {:ok, 2} = Sets.sintercard(conn, [k, k2])
    assert {:ok, 1} = Sets.sintercard(conn, [k, k2], limit: 1)
    HotKV.command(conn, ["DEL", dest])
  end

  test "SMOVE", %{conn: conn, k: k} do
    k2 = k <> ":2"
    Sets.sadd(conn, k, "a")
    assert {:ok, true} = Sets.smove(conn, k, k2, "a")
    assert {:ok, false} = Sets.sismember(conn, k, "a")
    assert {:ok, true} = Sets.sismember(conn, k2, "a")
  end

  test "sscan/3 streams every member", %{conn: conn, k: k} do
    Sets.sadd(conn, k, ["a", "b", "c"])
    streamed = conn |> Sets.sscan(k) |> Enum.to_list()
    assert Enum.sort(streamed) == ["a", "b", "c"]
  end
end

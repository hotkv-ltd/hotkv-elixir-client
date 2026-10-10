# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.HashesIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{Hashes, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("hash")
    on_exit(fn -> HotKV.command(conn, ["DEL", k]) end)
    {:ok, conn: conn, k: k}
  end

  test "HSET/HGET/HMGET/HGETALL/HDEL/HEXISTS/HKEYS/HVALS/HLEN/HSTRLEN", %{conn: conn, k: k} do
    assert {:ok, 2} = Hashes.hset(conn, k, [{"a", "1"}, {"b", "2"}])
    assert {:ok, "1"} = Hashes.hget(conn, k, "a")
    assert {:ok, nil} = Hashes.hget(conn, k, "missing")
    assert {:ok, ["1", "2", nil]} = Hashes.hmget(conn, k, ["a", "b", "c"])
    assert {:ok, %{"a" => "1", "b" => "2"}} = Hashes.hgetall(conn, k)
    assert {:ok, true} = Hashes.hexists(conn, k, "a")
    assert {:ok, false} = Hashes.hexists(conn, k, "z")
    assert {:ok, keys} = Hashes.hkeys(conn, k)
    assert Enum.sort(keys) == ["a", "b"]
    assert {:ok, vals} = Hashes.hvals(conn, k)
    assert Enum.sort(vals) == ["1", "2"]
    assert {:ok, 2} = Hashes.hlen(conn, k)
    assert {:ok, 1} = Hashes.hstrlen(conn, k, "a")
    assert {:ok, 1} = Hashes.hdel(conn, k, "a")
    assert {:ok, 1} = Hashes.hlen(conn, k)
  end

  test "HSETNX, HINCRBY, HINCRBYFLOAT", %{conn: conn, k: k} do
    assert {:ok, true} = Hashes.hsetnx(conn, k, "n", "1")
    assert {:ok, false} = Hashes.hsetnx(conn, k, "n", "2")
    assert {:ok, 6} = Hashes.hincrby(conn, k, "n", 5)
    assert {:ok, incremented} = Hashes.hincrbyfloat(conn, k, "n", 0.5)
    assert String.to_float(incremented) == 6.5
  end

  test "HRANDFIELD with and without count/WITHVALUES", %{conn: conn, k: k} do
    Hashes.hset(conn, k, [{"a", "1"}, {"b", "2"}])
    assert {:ok, field} = Hashes.hrandfield(conn, k)
    assert field in ["a", "b"]
    assert {:ok, fields} = Hashes.hrandfield(conn, k, 10)
    assert Enum.sort(fields) == ["a", "b"]
    assert {:ok, pairs} = Hashes.hrandfield(conn, k, 10, with_values: true)
    assert Enum.sort(pairs) == [{"a", "1"}, {"b", "2"}]
  end

  test "hscan/3 streams every {field, value} pair", %{conn: conn, k: k} do
    Hashes.hset(conn, k, [{"a", "1"}, {"b", "2"}])
    streamed = conn |> Hashes.hscan(k) |> Enum.to_list()
    assert Enum.sort(streamed) == [{"a", "1"}, {"b", "2"}]
  end

  test "per-field TTL: HEXPIRE/HTTL/HPERSIST/HEXPIRETIME family", %{conn: conn, k: k} do
    Hashes.hset(conn, k, [{"a", "1"}, {"b", "2"}])
    assert {:ok, [1, 1]} = Hashes.hexpire(conn, k, 1000, ["a", "b"])
    assert {:ok, [ttl_a, ttl_b]} = Hashes.httl(conn, k, ["a", "b"])
    assert ttl_a > 0 and ttl_b > 0
    assert {:ok, [pttl_a]} = Hashes.hpttl(conn, k, ["a"])
    assert pttl_a > 0
    assert {:ok, [et]} = Hashes.hexpiretime(conn, k, ["a"])
    assert et > 0
    assert {:ok, [pet]} = Hashes.hpexpiretime(conn, k, ["a"])
    assert pet > 0
    assert {:ok, [1, 1]} = Hashes.hpersist(conn, k, ["a", "b"])
    assert {:ok, [-1, -1]} = Hashes.httl(conn, k, ["a", "b"])
    assert {:ok, [-2]} = Hashes.httl(conn, k, ["no-such-field"])
    assert {:ok, [1]} = Hashes.hpexpire(conn, k, 500_000, ["a"])
    assert {:ok, [1]} = Hashes.hexpireat(conn, k, System.os_time(:second) + 1000, ["b"])
    assert {:ok, [_]} = Hashes.hpexpireat(conn, k, (System.os_time(:second) + 2000) * 1000, ["a"])
  end
end

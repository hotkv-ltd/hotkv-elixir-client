# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.SortedSetsIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{SortedSets, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    k = TestSupport.unique("zset")
    on_exit(fn -> HotKV.command(conn, ["DEL", k, k <> ":2", k <> ":dest"]) end)
    {:ok, conn: conn, k: k}
  end

  test "ZADD/ZSCORE/ZMSCORE/ZINCRBY/ZCARD/ZCOUNT/ZREM", %{conn: conn, k: k} do
    assert {:ok, 3} = SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
    assert {:ok, 1.0} = SortedSets.zscore(conn, k, "a")
    assert {:ok, nil} = SortedSets.zscore(conn, k, "z")
    assert {:ok, [1.0, nil, 3.0]} = SortedSets.zmscore(conn, k, ["a", "z", "c"])
    assert {:ok, 4.0} = SortedSets.zincrby(conn, k, 3.0, "a")
    assert {:ok, 3} = SortedSets.zcard(conn, k)
    assert {:ok, 3} = SortedSets.zcount(conn, k, "2", "+inf")
    assert {:ok, 1} = SortedSets.zrem(conn, k, "b")
    assert {:ok, 2} = SortedSets.zcard(conn, k)
  end

  test "ZADD NX/XX/GT/LT/CH/INCR", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{5.0, "m"}])
    assert {:ok, 0} = SortedSets.zadd(conn, k, [{10.0, "m"}], nx: true)
    assert {:ok, 5.0} = SortedSets.zscore(conn, k, "m")
    assert {:ok, 1} = SortedSets.zadd(conn, k, [{10.0, "m"}], gt: true, ch: true)
    assert {:ok, 10.0} = SortedSets.zscore(conn, k, "m")
    assert {:ok, 11.0} = SortedSets.zadd(conn, k, [{1.0, "m"}], incr: true)
    assert {:ok, nil} = SortedSets.zadd(conn, k, [{1.0, "m"}], incr: true, nx: true)
  end

  test "ZRANGE with BYSCORE/BYLEX/REV/LIMIT/WITHSCORES", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
    assert {:ok, ["a", "b", "c"]} = SortedSets.zrange(conn, k, 0, -1)

    assert {:ok, [{"a", 1.0}, {"b", 2.0}, {"c", 3.0}]} =
             SortedSets.zrange(conn, k, 0, -1, withscores: true)

    assert {:ok, ["c", "b", "a"]} = SortedSets.zrange(conn, k, 0, -1, rev: true)
    assert {:ok, ["b", "c"]} = SortedSets.zrange(conn, k, "2", "+inf", byscore: true)
    assert {:ok, ["a"]} = SortedSets.zrange(conn, k, "-inf", "+inf", byscore: true, limit: {0, 1})
  end

  test "legacy ZRANGEBYSCORE/ZREVRANGEBYSCORE/ZRANGEBYLEX/ZREVRANGEBYLEX/ZREVRANGE", %{
    conn: conn,
    k: k
  } do
    SortedSets.zadd(conn, k, [{0.0, "a"}, {0.0, "b"}, {0.0, "c"}])
    assert {:ok, ["a", "b", "c"]} = SortedSets.zrangebyscore(conn, k, "-inf", "+inf")
    assert {:ok, ["c", "b", "a"]} = SortedSets.zrevrangebyscore(conn, k, "+inf", "-inf")
    assert {:ok, ["a", "b", "c"]} = SortedSets.zrangebylex(conn, k, "-", "+")
    assert {:ok, ["c", "b", "a"]} = SortedSets.zrevrangebylex(conn, k, "+", "-")
    assert {:ok, ["c", "b", "a"]} = SortedSets.zrevrange(conn, k, 0, -1)
  end

  test "ZRANGESTORE", %{conn: conn, k: k} do
    dest = k <> ":dest"
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}, {4.0, "d"}])
    assert {:ok, 4} = SortedSets.zrangestore(conn, dest, k, 0, -1)
    assert {:ok, ["a", "b", "c", "d"]} = SortedSets.zrange(conn, dest, 0, -1)

    assert {:ok, 2} = SortedSets.zrangestore(conn, dest, k, "2", "3", byscore: true)
    assert {:ok, ["b", "c"]} = SortedSets.zrange(conn, dest, 0, -1)

    assert {:ok, 2} =
             SortedSets.zrangestore(conn, dest, k, "4", "1",
               byscore: true,
               rev: true,
               limit: {0, 2}
             )

    assert {:ok, ["c", "d"]} = SortedSets.zrange(conn, dest, 0, -1)

    klex = k <> ":lex"
    SortedSets.zadd(conn, klex, [{0.0, "a"}, {0.0, "b"}, {0.0, "c"}])
    assert {:ok, 3} = SortedSets.zrangestore(conn, dest, klex, "-", "+", bylex: true)
    assert {:ok, ["a", "b", "c"]} = SortedSets.zrange(conn, dest, 0, -1)
  end

  test "ZRANK/ZREVRANK with WITHSCORE", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}])
    assert {:ok, 0} = SortedSets.zrank(conn, k, "a")
    assert {:ok, 1} = SortedSets.zrevrank(conn, k, "a")
    assert {:ok, {0, 1.0}} = SortedSets.zrank(conn, k, "a", withscore: true)
    assert {:ok, nil} = SortedSets.zrank(conn, k, "missing")
  end

  test "ZREMRANGEBYRANK/SCORE/LEX", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
    assert {:ok, 1} = SortedSets.zremrangebyrank(conn, k, 0, 0)
    assert {:ok, 2} = SortedSets.zcard(conn, k)
    assert {:ok, 1} = SortedSets.zremrangebyscore(conn, k, "3", "3")
    assert {:ok, 1} = SortedSets.zcard(conn, k)
    assert {:ok, 1} = SortedSets.zremrangebylex(conn, k, "-", "+")
    assert {:ok, 0} = SortedSets.zcard(conn, k)
  end

  test "ZUNION/ZINTER/ZDIFF and their *STORE variants", %{conn: conn, k: k} do
    k2 = k <> ":2"
    dest = k <> ":dest"
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}])
    SortedSets.zadd(conn, k2, [{10.0, "b"}, {10.0, "c"}])

    assert {:ok, ["a", "c", "b"]} = SortedSets.zunion(conn, [k, k2])

    assert {:ok, [{"a", 1.0}, {"c", 10.0}, {"b", 12.0}]} =
             SortedSets.zunion(conn, [k, k2], withscores: true)

    assert {:ok, ["b"]} = SortedSets.zinter(conn, [k, k2])
    assert {:ok, ["a"]} = SortedSets.zdiff(conn, [k, k2])

    assert {:ok, 3} =
             SortedSets.zunionstore(conn, dest, [k, k2], weights: [1, 1], aggregate: :max)

    assert {:ok, 1} = SortedSets.zinterstore(conn, dest, [k, k2])
    assert {:ok, 1} = SortedSets.zdiffstore(conn, dest, [k, k2])
    assert {:ok, 1} = SortedSets.zintercard(conn, [k, k2])
    HotKV.command(conn, ["DEL", dest])
  end

  test "ZPOPMIN/ZPOPMAX and ZRANDMEMBER", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
    assert {:ok, [{"a", 1.0}]} = SortedSets.zpopmin(conn, k)
    assert {:ok, [{"c", 3.0}]} = SortedSets.zpopmax(conn, k)
    assert {:ok, member} = SortedSets.zrandmember(conn, k)
    assert member == "b"
    assert {:ok, [{"b", 2.0}]} = SortedSets.zrandmember(conn, k, 1, withscores: true)
  end

  test "zscan/3 streams every {member, score}", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{1.0, "a"}, {2.0, "b"}])
    streamed = conn |> SortedSets.zscan(k) |> Enum.to_list()
    assert Enum.sort(streamed) == [{"a", 1.0}, {"b", 2.0}]
  end

  test "ZLEXCOUNT", %{conn: conn, k: k} do
    SortedSets.zadd(conn, k, [{0.0, "a"}, {0.0, "b"}, {0.0, "c"}])
    assert {:ok, 3} = SortedSets.zlexcount(conn, k, "-", "+")
  end
end

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RespShapesTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  # Checks that HGETALL, HRANDFIELD WITHVALUES, SMEMBERS, ZSCORE, ZRANGE
  # WITHSCORES, ZPOPMIN with a count, ZRANDMEMBER WITHSCORES, XREAD, XINFO
  # STREAM, CONFIG GET and INFO decode to the same shape whether the
  # connection negotiated RESP3 (the default) or RESP2.

  alias HotKV.{Hashes, Server, Sets, SortedSets, Streams, TestSupport}

  test "RESP3" do
    run_checks(TestSupport.start_conn(resp3: true), "resp3")
  end

  test "RESP2" do
    run_checks(TestSupport.start_conn(resp3: false), "resp2")
  end

  defp run_checks(conn, label) do
    hkey = TestSupport.unique("shape-#{label}-hash")
    skey = TestSupport.unique("shape-#{label}-set")
    zkey = TestSupport.unique("shape-#{label}-zset")
    xkey = TestSupport.unique("shape-#{label}-stream")
    on_exit(fn -> HotKV.command(conn, ["DEL", hkey, skey, zkey, xkey]) end)

    assert {:ok, 2} = Hashes.hset(conn, hkey, [{"f1", "v1"}, {"f2", "v2"}])
    assert {:ok, %{"f1" => "v1", "f2" => "v2"}} = Hashes.hgetall(conn, hkey)

    assert {:ok, fvs} = Hashes.hrandfield(conn, hkey, 2, with_values: true)
    assert length(fvs) == 2

    Enum.each(fvs, fn {field, value} ->
      assert value == if(field == "f1", do: "v1", else: "v2")
    end)

    assert {:ok, 3} = Sets.sadd(conn, skey, ["a", "b", "c"])
    assert {:ok, members} = Sets.smembers(conn, skey)
    assert MapSet.new(members) == MapSet.new(["a", "b", "c"])

    assert {:ok, 3} = SortedSets.zadd(conn, zkey, [{1.0, "a"}, {2.0, "b"}, {3.0, "c"}])
    assert {:ok, 2.0} = SortedSets.zscore(conn, zkey, "b")

    assert {:ok, [{"a", 1.0}, {"b", 2.0}, {"c", 3.0}]} =
             SortedSets.zrange(conn, zkey, 0, -1, withscores: true)

    assert {:ok, [{"a", 1.0}, {"b", 2.0}]} = SortedSets.zpopmin(conn, zkey, 2)

    assert {:ok, 2} = SortedSets.zadd(conn, zkey, [{1.0, "a"}, {2.0, "b"}])
    assert {:ok, rand_scored} = SortedSets.zrandmember(conn, zkey, 3, withscores: true)
    assert length(rand_scored) == 3

    assert {:ok, id1} = Streams.xadd(conn, xkey, "*", [{"field1", "v1"}])
    assert {:ok, id2} = Streams.xadd(conn, xkey, "*", [{"field2", "v2"}])
    assert {:ok, streams} = Streams.xread(conn, [{xkey, "0"}])
    assert Map.keys(streams) == [xkey]
    entries = streams[xkey]
    assert length(entries) == 2
    assert {^id1, %{"field1" => "v1"}} = Enum.at(entries, 0)
    assert {^id2, _} = Enum.at(entries, 1)

    assert {:ok, info} = Streams.xinfo_stream(conn, xkey)
    assert info["length"] == 2
    assert info["last-generated-id"] == id2

    assert {:ok, cfg} = Server.config_get(conn, "maxmemory")
    assert Map.has_key?(cfg, "maxmemory")

    assert {:ok, info_str} = Server.info(conn)
    refute String.starts_with?(info_str, "txt:")
    refute String.starts_with?(info_str, "mkd:")
    assert info_str =~ "hotkv_version"
  end
end

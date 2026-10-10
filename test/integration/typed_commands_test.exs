# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TypedCommandsIntegrationTest do
  @moduledoc """
  Live tests for typed functions no other integration test calls, plus the
  newer and HotKV core commands added to the typed modules (compare-and-set
  `SET`, `DIGEST`, `DELEX`, `MSETEX`, `HGETDEL`, `HGETEX`, `HSETEX`,
  `XCFGSET`, `PUBLISH` and the `PUBSUB` subcommands).
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{
    AgentMemory,
    Channels,
    Hashes,
    Lists,
    PubSub,
    Server,
    Streams,
    Strings,
    TestSupport
  }

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  defp key(label), do: TestSupport.unique(label)

  describe "SET conditions, DIGEST, DELEX, MSETEX" do
    test "SET IFEQ / IFNE / IFDEQ / IFDNE", %{conn: conn} do
      k = key("cas")
      on_exit(fn -> HotKV.command(conn, ["DEL", k]) end)

      assert {:ok, "OK"} = Strings.set(conn, k, "v1")
      # the condition holds: replaced
      assert {:ok, "OK"} = Strings.set(conn, k, "v2", ifeq: "v1")
      assert {:ok, "v2"} = Strings.get(conn, k)
      # the condition fails: nil, value unchanged
      assert {:ok, nil} = Strings.set(conn, k, "v3", ifeq: "nope")
      assert {:ok, "v2"} = Strings.get(conn, k)
      assert {:ok, "OK"} = Strings.set(conn, k, "v3", ifne: "nope")

      {:ok, digest} = Strings.digest(conn, k)
      assert digest =~ ~r/\A[0-9a-f]{16}\z/
      assert {:ok, nil} = Strings.set(conn, k, "v4", ifdeq: "0000000000000000")
      assert {:ok, "OK"} = Strings.set(conn, k, "v4", ifdeq: digest)
      assert {:ok, "OK"} = Strings.set(conn, k, "v5", ifdne: "0000000000000000")
      assert {:ok, "v5"} = Strings.get(conn, k)
    end

    test "DIGEST is nil for a missing key and stable for equal values", %{conn: conn} do
      k = key("digest")
      k2 = key("digest2")
      on_exit(fn -> HotKV.command(conn, ["DEL", k, k2]) end)

      assert {:ok, nil} = Strings.digest(conn, k)
      Strings.set(conn, k, "same")
      Strings.set(conn, k2, "same")
      assert {:ok, d} = Strings.digest(conn, k)
      assert {:ok, ^d} = Strings.digest(conn, k2)
    end

    test "DELEX deletes unconditionally or only when the condition holds", %{conn: conn} do
      k = key("delex")
      on_exit(fn -> HotKV.command(conn, ["DEL", k]) end)

      assert {:ok, false} = Strings.delex(conn, k)
      Strings.set(conn, k, "v")
      assert {:ok, false} = Strings.delex(conn, k, ifeq: "x")
      assert {:ok, 1} = HotKV.Keys.exists(conn, k)
      assert {:ok, true} = Strings.delex(conn, k, ifeq: "v")
      assert {:ok, false} = Strings.delex(conn, k)

      Strings.set(conn, k, "v")
      {:ok, digest} = Strings.digest(conn, k)
      assert {:ok, false} = Strings.delex(conn, k, ifdne: digest)
      assert {:ok, true} = Strings.delex(conn, k, ifdeq: digest)

      Strings.set(conn, k, "v")
      assert {:ok, true} = Strings.delex(conn, k, ifne: "other")
    end

    test "MSETEX sets several keys with one TTL", %{conn: conn} do
      a = key("msetex:a")
      b = key("msetex:b")
      on_exit(fn -> HotKV.command(conn, ["DEL", a, b]) end)

      assert {:ok, true} = Strings.msetex(conn, [{a, "1"}, {b, "2"}], ex: 100)
      assert {:ok, ["1", "2"]} = Strings.mget(conn, [a, b])
      assert {:ok, ttl} = HotKV.Keys.ttl(conn, a)
      assert ttl in 98..100
      assert {:ok, ttl_b} = HotKV.Keys.ttl(conn, b)
      assert ttl_b in 98..100

      # NX fails once the keys exist, XX succeeds
      assert {:ok, false} = Strings.msetex(conn, [a, "x", b, "y"], nx: true)
      assert {:ok, ["1", "2"]} = Strings.mget(conn, [a, b])
      assert {:ok, true} = Strings.msetex(conn, [a, "x", b, "y"], xx: true, px: 50_000)
      assert {:ok, ["x", "y"]} = Strings.mget(conn, [a, b])
    end
  end

  describe "hash field commands" do
    test "HGETDEL returns and removes the fields", %{conn: conn} do
      h = key("hgetdel")
      on_exit(fn -> HotKV.command(conn, ["DEL", h]) end)

      Hashes.hset(conn, h, [{"f1", "v1"}, {"f2", "v2"}, {"f3", "v3"}])
      assert {:ok, ["v1", nil]} = Hashes.hgetdel(conn, h, ["f1", "missing"])
      assert {:ok, false} = Hashes.hexists(conn, h, "f1")
      assert {:ok, 2} = Hashes.hlen(conn, h)
    end

    test "HGETEX returns the fields and changes their TTLs", %{conn: conn} do
      h = key("hgetex")
      on_exit(fn -> HotKV.command(conn, ["DEL", h]) end)

      Hashes.hset(conn, h, [{"f1", "v1"}, {"f2", "v2"}])
      assert {:ok, ["v1", nil]} = Hashes.hgetex(conn, h, ["f1", "zz"], ex: 100)
      assert {:ok, [ttl]} = Hashes.httl(conn, h, ["f1"])
      assert ttl in 98..100
      assert {:ok, [-1]} = Hashes.httl(conn, h, ["f2"])

      assert {:ok, ["v1"]} = Hashes.hgetex(conn, h, ["f1"], persist: true)
      assert {:ok, [-1]} = Hashes.httl(conn, h, ["f1"])
      assert {:ok, ["v1", "v2"]} = Hashes.hgetex(conn, h, ["f1", "f2"])
    end

    test "HSETEX sets fields with a TTL, all or none", %{conn: conn} do
      h = key("hsetex")
      on_exit(fn -> HotKV.command(conn, ["DEL", h]) end)

      assert {:ok, true} = Hashes.hsetex(conn, h, [{"g1", "w1"}, {"g2", "w2"}], ex: 50)
      assert {:ok, %{"g1" => "w1", "g2" => "w2"}} = Hashes.hgetall(conn, h)
      assert {:ok, [ttl, ttl2]} = Hashes.httl(conn, h, ["g1", "g2"])
      assert ttl in 48..50 and ttl2 in 48..50

      # FNX: refused because g1 exists, nothing is written
      assert {:ok, false} = Hashes.hsetex(conn, h, [{"g1", "zz"}, {"g3", "w3"}], fnx: true)
      assert {:ok, false} = Hashes.hexists(conn, h, "g3")
      # FXX: all fields exist, so it applies
      assert {:ok, true} = Hashes.hsetex(conn, h, ["g1", "new"], fxx: true, keepttl: true)
      assert {:ok, "new"} = Hashes.hget(conn, h, "g1")
    end
  end

  test "XCFGSET sets the idempotency limits of an existing stream", %{conn: conn} do
    s = key("xcfgset")
    on_exit(fn -> HotKV.command(conn, ["DEL", s]) end)

    assert {:error, %HotKV.Error{kind: :server}} = Streams.xcfgset(conn, s, idmp_duration: 10)
    assert {:ok, _id} = Streams.xadd(conn, s, "*", [{"a", "1"}])
    assert {:ok, "OK"} = Streams.xcfgset(conn, s, idmp_duration: 100, idmp_maxsize: 50)
    assert {:ok, info} = Streams.xinfo_stream(conn, s)
    assert info["idmp-duration"] == 100
    assert info["idmp-maxsize"] == 50
  end

  describe "HotKV.Channels" do
    setup %{conn: conn} do
      {:ok, pubsub} = PubSub.start_link(url: TestSupport.test_url())
      {:ok, conn: conn, pubsub: pubsub}
    end

    test "PUBLISH reaches subscribers; PUBSUB reports channels, NUMSUB and NUMPAT", %{
      conn: conn,
      pubsub: pubsub
    } do
      ch = key("chan")
      ch2 = key("chan2")
      pat = key("pat") <> "*"

      assert {:ok, 0} = Channels.publish(conn, ch, "nobody listens")

      :ok = PubSub.subscribe(pubsub, [ch, ch2])
      :ok = PubSub.psubscribe(pubsub, [pat])
      Process.sleep(150)

      assert {:ok, 1} = Channels.publish(conn, ch, "hello")
      assert_receive {:hotkv_pubsub, ^pubsub, :message, %{channel: ^ch, payload: "hello"}}, 1000

      assert {:ok, active} = Channels.channels(conn)
      assert ch in active and ch2 in active
      assert {:ok, [^ch]} = Channels.channels(conn, ch)

      assert {:ok, %{^ch => 1, ^ch2 => 1}} = Channels.numsub(conn, [ch, ch2])

      assert {:ok, %{"never-subscribed-xyz" => 0}} =
               Channels.numsub(conn, ["never-subscribed-xyz"])

      assert {:ok, patterns} = Channels.numpat(conn)
      assert patterns >= 1

      :ok = PubSub.punsubscribe(pubsub, [pat])
      :ok = PubSub.unsubscribe(pubsub, [ch, ch2])
      Process.sleep(150)
      assert {:ok, %{^ch => 0}} = Channels.numsub(conn, [ch])
    end

    test "SPUBLISH and the shard variants of PUBSUB", %{conn: conn, pubsub: pubsub} do
      sch = key("schan")
      :ok = PubSub.ssubscribe(pubsub, [sch])
      Process.sleep(150)

      assert {:ok, 1} = Channels.spublish(conn, sch, "shard-msg")

      assert_receive {:hotkv_pubsub, ^pubsub, :smessage, %{channel: ^sch, payload: "shard-msg"}},
                     1000

      assert {:ok, active} = Channels.shard_channels(conn)
      assert sch in active
      assert {:ok, %{^sch => 1}} = Channels.shard_numsub(conn, [sch])

      :ok = PubSub.sunsubscribe(pubsub, [sch])
      Process.sleep(150)
      assert {:ok, %{^sch => 0}} = Channels.shard_numsub(conn, [sch])
      assert {:ok, 0} = Channels.spublish(conn, sch, "after unsubscribe")
    end
  end

  describe "blocking list commands" do
    test "BRPOP and BLMOVE return immediately when data is waiting and nil on timeout", %{
      conn: conn
    } do
      l = key("blist")
      dest = key("blist:dest")
      empty = key("blist:empty")
      on_exit(fn -> HotKV.command(conn, ["DEL", l, dest, empty]) end)

      Lists.rpush(conn, l, ["a", "b", "c"])
      assert {:ok, [^l, "c"]} = Lists.brpop(conn, l, 1)
      assert {:ok, [^l, "a"]} = Lists.blpop(conn, [empty, l], 1)

      assert {:ok, "b"} = Lists.blmove(conn, l, dest, :left, :right, 1)
      assert {:ok, ["b"]} = Lists.lrange(conn, dest, 0, -1)

      assert {:ok, nil} = Lists.brpop(conn, empty, 0.2)
      assert {:ok, nil} = Lists.blmove(conn, empty, dest, :left, :left, 0.2)
    end
  end

  describe "server administration" do
    test "CONFIG SET round-trips a value", %{conn: conn} do
      assert {:ok, %{"slowlog-max-len" => old}} = Server.config_get(conn, "slowlog-max-len")
      on_exit(fn -> Server.config_set(conn, "slowlog-max-len", old) end)

      assert {:ok, "OK"} = Server.config_set(conn, "slowlog-max-len", "129")
      assert {:ok, %{"slowlog-max-len" => "129"}} = Server.config_get(conn, "slowlog-max-len")
      assert {:ok, "OK"} = Server.config_set(conn, "slowlog-max-len", old)
      assert {:ok, %{"slowlog-max-len" => ^old}} = Server.config_get(conn, "slowlog-max-len")
    end

    test "FLUSHDB empties only the selected database" do
      # database 9 is used by no other test; the flush must leave database 0 alone
      {:ok, db9} = HotKV.start_link(url: TestSupport.test_url(), database: 9)
      {:ok, db0} = HotKV.start_link(url: TestSupport.test_url(), database: 0)
      k0 = key("flushdb:db0")
      on_exit(fn -> HotKV.command(db0, ["DEL", k0]) end)

      assert {:ok, "OK"} = Strings.set(db9, "in9", "v")
      assert {:ok, "OK"} = Strings.set(db0, k0, "v")
      assert {:ok, "OK"} = Server.flushdb(db9)
      assert {:ok, 0} = Server.dbsize(db9)
      assert {:ok, "v"} = Strings.get(db0, k0)

      assert {:ok, "OK"} = Strings.set(db9, "in9", "v")
      assert {:ok, "OK"} = Server.flushdb(db9, :sync)
      assert {:ok, nil} = Strings.get(db9, "in9")
      assert {:ok, "OK"} = Strings.set(db9, "in9", "v")
      assert {:ok, "OK"} = Server.flushdb(db9, :async)
      Process.sleep(100)
      assert {:ok, nil} = Strings.get(db9, "in9")
    end

    @tag :flushall
    test "FLUSHALL empties every database (needs HOTKV_TEST_FLUSHALL_URL, a disposable server)" do
      case System.get_env("HOTKV_TEST_FLUSHALL_URL") do
        nil ->
          IO.puts(
            "      SKIP: HOTKV_TEST_FLUSHALL_URL not set (FLUSHALL would wipe a shared server)"
          )

        url ->
          {:ok, a} = HotKV.start_link(url: url, database: 0)
          {:ok, b} = HotKV.start_link(url: url, database: 5)
          Strings.set(a, "fa", "1")
          Strings.set(b, "fb", "2")
          assert {:ok, "OK"} = Server.flushall(a)
          assert {:ok, 0} = Server.dbsize(a)
          assert {:ok, 0} = Server.dbsize(b)

          Strings.set(a, "fa", "1")
          assert {:ok, "OK"} = Server.flushall(a, :async)
          Process.sleep(100)
          assert {:ok, 0} = Server.dbsize(a)
          assert {:ok, "OK"} = Server.flushall(a, :sync)
      end
    end
  end

  test "AMEM.WORK.CLEAR drops a session's working memory", %{conn: conn} do
    sess = key("worksess")
    on_exit(fn -> AgentMemory.work_clear(conn, sess) end)

    AgentMemory.work_set(conn, sess, "k", "v")
    |> TestSupport.licensed_or_skip(fn result ->
      assert {:ok, "OK"} = result
      assert {:ok, ["k"]} = AgentMemory.work_list(conn, sess)
      assert {:ok, true} = AgentMemory.work_clear(conn, sess)
      assert {:ok, []} = AgentMemory.work_list(conn, sess)
      # the session stays registered (empty) after a clear, so this is true again
      assert {:ok, true} = AgentMemory.work_clear(conn, sess)
      assert {:ok, false} = AgentMemory.work_clear(conn, key("never-created"))
    end)
  end

  describe "commands without a typed function are reachable with HotKV.command/3" do
    test "HMSET, LCS, SORT and LMPOP", %{conn: conn} do
      h = key("generic:h")
      s1 = key("generic:s1")
      s2 = key("generic:s2")
      l = key("generic:l")
      on_exit(fn -> HotKV.command(conn, ["DEL", h, s1, s2, l]) end)

      assert {:ok, "OK"} = HotKV.command(conn, ["HMSET", h, "a", "1", "b", "2"])
      assert {:ok, %{"a" => "1", "b" => "2"}} = Hashes.hgetall(conn, h)

      Strings.set(conn, s1, "ohmytext")
      Strings.set(conn, s2, "mynewtext")
      assert {:ok, "mytext"} = HotKV.command(conn, ["LCS", s1, s2])
      assert {:ok, 6} = HotKV.command(conn, ["LCS", s1, s2, "LEN"])

      Lists.rpush(conn, l, ["3", "1", "2"])
      assert {:ok, ["1", "2", "3"]} = HotKV.command(conn, ["SORT", l])
      assert {:ok, ["3", "2", "1"]} = HotKV.command(conn, ["SORT", l, "DESC"])
      assert {:ok, [^l, ["2", "1"]]} = HotKV.command(conn, ["LMPOP", 1, l, "RIGHT", "COUNT", 2])
    end
  end
end

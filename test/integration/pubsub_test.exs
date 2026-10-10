# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PubSubIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.{PubSub, TestSupport}

  setup do
    conn = TestSupport.start_conn()
    {:ok, pubsub} = PubSub.start_link(url: TestSupport.test_url())
    {:ok, conn: conn, pubsub: pubsub}
  end

  test "SUBSCRIBE delivers PUBLISH messages to the subscriber process", %{
    conn: conn,
    pubsub: pubsub
  } do
    channel = TestSupport.unique("chan")
    :ok = PubSub.subscribe(pubsub, [channel])
    Process.sleep(100)

    assert {:ok, 1} = HotKV.command(conn, ["PUBLISH", channel, "hello"])

    assert_receive {:hotkv_pubsub, ^pubsub, :message, %{channel: ^channel, payload: "hello"}},
                   1000
  end

  test "PSUBSCRIBE delivers pattern messages", %{conn: conn, pubsub: pubsub} do
    prefix = TestSupport.unique("pchan")
    pattern = prefix <> ".*"
    :ok = PubSub.psubscribe(pubsub, [pattern])
    Process.sleep(100)

    channel = prefix <> ".news"
    assert {:ok, 1} = HotKV.command(conn, ["PUBLISH", channel, "world"])

    assert_receive {:hotkv_pubsub, ^pubsub, :pmessage,
                    %{pattern: ^pattern, channel: ^channel, payload: "world"}},
                   1000
  end

  test "SSUBSCRIBE delivers SPUBLISH shard messages", %{conn: conn, pubsub: pubsub} do
    channel = TestSupport.unique("schan")
    :ok = PubSub.ssubscribe(pubsub, [channel])
    Process.sleep(100)

    assert {:ok, 1} = HotKV.command(conn, ["SPUBLISH", channel, "shard-hello"])

    assert_receive {:hotkv_pubsub, ^pubsub, :smessage,
                    %{channel: ^channel, payload: "shard-hello"}},
                   1000
  end

  test "UNSUBSCRIBE stops further deliveries to that subscriber", %{conn: conn, pubsub: pubsub} do
    channel = TestSupport.unique("chan")
    :ok = PubSub.subscribe(pubsub, [channel])
    Process.sleep(100)
    :ok = PubSub.unsubscribe(pubsub, [channel])
    Process.sleep(100)

    HotKV.command(conn, ["PUBLISH", channel, "should-not-arrive"])
    refute_receive {:hotkv_pubsub, _, :message, _}, 300
  end

  test "multiple local subscribers on the same channel each get the message", %{
    conn: conn,
    pubsub: pubsub
  } do
    channel = TestSupport.unique("chan")
    parent = self()

    other =
      spawn(fn ->
        PubSub.subscribe(pubsub, [channel], self())

        receive do
          {:hotkv_pubsub, _, :message, %{payload: payload}} -> send(parent, {:other_got, payload})
        after
          1000 -> send(parent, :other_timeout)
        end
      end)

    :ok = PubSub.subscribe(pubsub, [channel])
    Process.sleep(100)

    HotKV.command(conn, ["PUBLISH", channel, "fanout"])

    assert_receive {:hotkv_pubsub, ^pubsub, :message, %{payload: "fanout"}}, 1000
    assert_receive {:other_got, "fanout"}, 1000
    Process.exit(other, :kill)
  end

  test "subscriptions/1 reports the current channel/pattern/schannel sets", %{pubsub: pubsub} do
    channel = TestSupport.unique("chan")
    :ok = PubSub.subscribe(pubsub, [channel])
    assert %{channel: channels} = PubSub.subscriptions(pubsub)
    assert channel in channels
  end

  test "subscribe returns only after the server acknowledged it (no sleep needed)", %{
    conn: conn,
    pubsub: pubsub
  } do
    for i <- 1..20 do
      channel = TestSupport.unique("ackchan#{i}")
      pattern = channel <> "*"
      :ok = PubSub.subscribe(pubsub, [channel])
      :ok = PubSub.psubscribe(pubsub, [pattern])
      assert {:ok, 2} = HotKV.command(conn, ["PUBLISH", channel, "now"])

      assert_receive {:hotkv_pubsub, ^pubsub, :message, %{channel: ^channel, payload: "now"}},
                     1000

      assert_receive {:hotkv_pubsub, ^pubsub, :pmessage, %{pattern: ^pattern, payload: "now"}},
                     1000

      :ok = PubSub.unsubscribe(pubsub, [channel])
      :ok = PubSub.punsubscribe(pubsub, [pattern])
      assert {:ok, 0} = HotKV.command(conn, ["PUBLISH", channel, "later"])
    end
  end
end

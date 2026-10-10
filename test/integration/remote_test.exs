# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.RemoteIntegrationTest do
  @moduledoc """
  A customer's view: connect over the network to a TLS + password HotKV
  server and use it. Skipped unless `HOTKV_REMOTE_HOST` is set.

  Environment:

    * `HOTKV_REMOTE_HOST` - server host (the certificate must name it)
    * `HOTKV_REMOTE_PORT` - TLS port (default 6379)
    * `HOTKV_REMOTE_PASSWORD` - the `default` user's password; read only
      here, never printed or stored
    * `HOTKV_REMOTE_CA` - path to the PEM file of the CA (or the
      self-signed certificate) that issued the server certificate

  The server is shared: every key and namespace carries a per-run
  `remote-elixir-<random>` prefix and is removed afterwards. Nothing here
  touches global state (no FLUSH*, CONFIG, ACL, SHUTDOWN, ALERTS).
  """
  use ExUnit.Case, async: false
  @moduletag :remote
  @moduletag timeout: 120_000

  alias HotKV.{
    AgentMemory,
    EmbedDedup,
    FeatureStore,
    GuardCache,
    Gcra,
    Geo,
    Hashes,
    Lists,
    LLMBudget,
    LLMStats,
    NegativeCache,
    PromptCache,
    PromptRegistry,
    PubSub,
    RAG,
    RateLimit,
    RerankCache,
    SemanticCache,
    Server,
    SortedSets,
    Sets,
    Streams,
    Strings,
    TimeSeries,
    TokenUsage,
    ToolCache,
    Vsim
  }

  # -- connection helpers -------------------------------------------------

  defp host, do: System.fetch_env!("HOTKV_REMOTE_HOST")
  defp port, do: System.get_env("HOTKV_REMOTE_PORT", "6379") |> String.to_integer()
  defp ca, do: System.fetch_env!("HOTKV_REMOTE_CA")
  defp password, do: System.fetch_env!("HOTKV_REMOTE_PASSWORD")

  defp url_with(secret),
    do: "hotkvs://default:#{URI.encode(secret, &URI.char_unreserved?/1)}@#{host()}:#{port()}"

  # URL form: hotkvs:// carries the TLS switch, user and password.
  defp connect_url(extra \\ []) do
    {:ok, conn} =
      HotKV.start_link([url: url_with(password()), tls_opts: [ca_file: ca()]] ++ extra)

    conn
  end

  # Options form.
  defp connect_opts(extra \\ []) do
    {:ok, conn} =
      HotKV.start_link(
        [
          host: host(),
          port: port(),
          username: "default",
          password: password(),
          tls: true,
          tls_opts: [ca_file: ca()],
          client_name: "remote-elixir-test"
        ] ++ extra
      )

    conn
  end

  setup_all do
    prefix = "remote-elixir-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    conn = connect_url()
    on_exit(fn -> :ok end)
    {:ok, prefix: prefix, conn: conn}
  end

  setup %{conn: conn, prefix: prefix} do
    on_exit(fn ->
      # remove whatever this test left under the run's prefix (only our keys)
      cleaner = connect_url()

      cleaner
      |> HotKV.Keys.scan(match: prefix <> "*", count: 200)
      |> Enum.chunk_every(100)
      |> Enum.each(&HotKV.Keys.del(cleaner, &1))
    end)

    {:ok, conn: conn}
  end

  defp key(prefix, label), do: "#{prefix}:#{label}:#{System.unique_integer([:positive])}"

  # Names usable as namespaces / agent ids: no characters that confuse the
  # per-family name rules.
  defp ns(prefix, label), do: String.replace(key(prefix, label), ":", "-")

  defp wait_until(fun, tries) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached in time")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end

  # -- connecting, authentication, TLS ---------------------------------------

  describe "connecting" do
    test "PING over hotkvs:// with the password in the URL", %{conn: conn} do
      assert {:ok, "PONG"} = Server.ping(conn)
      assert {:ok, "hello"} = Server.ping(conn, "hello")
      assert HotKV.connected?(conn)
      assert HotKV.Connection.resp3?(conn)
    end

    test "PING with the options form (host, port, username, password, tls_opts)" do
      conn = connect_opts()
      assert {:ok, "PONG"} = Server.ping(conn)
      assert {:ok, "remote-elixir-test"} = Server.client_getname(conn)
    end

    test "RESP2 over TLS with a password" do
      conn = connect_opts(resp3: false)
      refute HotKV.Connection.resp3?(conn)
      assert {:ok, "PONG"} = Server.ping(conn)
    end

    test "a wrong password fails cleanly, without crashing the caller" do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          result =
            HotKV.start_link(
              host: host(),
              port: port(),
              password: "wrong-" <> Base.encode16(:crypto.strong_rand_bytes(6)),
              tls: true,
              tls_opts: [ca_file: ca()]
            )

          send(parent, {:result, result})
        end)

      assert_receive {:result, {:error, %HotKV.Error{kind: :server, prefix: prefix}}}, 10_000
      assert prefix in ["WRONGPASS", "NOAUTH", "ERR"]
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "no password is refused" do
      assert {:error, %HotKV.Error{kind: :server}} =
               HotKV.start_link(host: host(), port: port(), tls: true, tls_opts: [ca_file: ca()])
    end

    test "certificate verification is on: without the CA the self-signed certificate is rejected" do
      assert {:error, %HotKV.Error{kind: :connection}} =
               HotKV.start_link(
                 host: host(),
                 port: port(),
                 password: password(),
                 tls: true,
                 connect_timeout: 8_000
               )
    end

    test "plain TCP against the TLS port is an error, not a hang" do
      assert {:error, %HotKV.Error{}} =
               HotKV.start_link(
                 host: host(),
                 port: port(),
                 password: password(),
                 connect_timeout: 3_000
               )
    end

    test "insecure_skip_verify connects without the CA (the one test of that option)" do
      {:ok, conn} =
        HotKV.start_link(
          host: host(),
          port: port(),
          password: password(),
          tls: true,
          tls_opts: [insecure_skip_verify: true]
        )

      assert {:ok, "PONG"} = Server.ping(conn)
    end
  end

  # -- core data types ----------------------------------------------------

  describe "data types over TLS" do
    test "strings", %{conn: conn, prefix: p} do
      k = key(p, "str")
      assert {:ok, "OK"} = Strings.set(conn, k, "hello")
      assert {:ok, "hello"} = Strings.get(conn, k)
      assert {:ok, 11} = Strings.append(conn, k, " world")
      assert {:ok, "hello world"} = Strings.get(conn, k)
      assert {:ok, 5} = Strings.incrby(conn, key(p, "ctr"), 5)
      assert {:ok, ["hello world", nil]} = Strings.mget(conn, [k, key(p, "missing")])
      assert {:ok, nil} = Strings.set(conn, k, "x", nx: true)
    end

    test "hashes", %{conn: conn, prefix: p} do
      k = key(p, "hash")
      assert {:ok, 2} = Hashes.hset(conn, k, [{"a", "1"}, {"b", "2"}])
      assert {:ok, "1"} = Hashes.hget(conn, k, "a")
      assert {:ok, %{"a" => "1", "b" => "2"}} = Hashes.hgetall(conn, k)
      assert {:ok, 3} = Hashes.hincrby(conn, k, "a", 2)
      assert {:ok, 1} = Hashes.hdel(conn, k, "b")
      assert {:ok, 1} = Hashes.hlen(conn, k)
    end

    test "lists", %{conn: conn, prefix: p} do
      k = key(p, "list")
      assert {:ok, 3} = Lists.rpush(conn, k, ["a", "b", "c"])
      assert {:ok, ["a", "b", "c"]} = Lists.lrange(conn, k, 0, -1)
      assert {:ok, "a"} = Lists.lpop(conn, k)
      assert {:ok, 2} = Lists.llen(conn, k)
      assert {:ok, [^k, "c"]} = Lists.brpop(conn, k, 1)
    end

    test "sets", %{conn: conn, prefix: p} do
      k = key(p, "set")
      assert {:ok, 3} = Sets.sadd(conn, k, ["a", "b", "c"])
      assert {:ok, true} = Sets.sismember(conn, k, "a")
      assert {:ok, 3} = Sets.scard(conn, k)
      {:ok, members} = Sets.smembers(conn, k)
      assert Enum.sort(MapSet.to_list(members)) == ["a", "b", "c"]
    end

    test "sorted sets", %{conn: conn, prefix: p} do
      k = key(p, "zset")
      assert {:ok, 3} = SortedSets.zadd(conn, k, [{1.0, "a"}, {2.5, "b"}, {1.0e-5, "tiny"}])
      assert {:ok, ["tiny", "a", "b"]} = SortedSets.zrange(conn, k, 0, -1)
      assert {:ok, 2.5} = SortedSets.zscore(conn, k, "b")

      assert {:ok, [{"tiny", 1.0e-5}, {"a", 1.0}]} =
               SortedSets.zrange(conn, k, 0, 1, withscores: true)

      assert {:ok, 0} = SortedSets.zrank(conn, k, "tiny")
    end

    test "streams", %{conn: conn, prefix: p} do
      k = key(p, "stream")
      assert {:ok, id} = Streams.xadd(conn, k, "*", [{"f", "v"}])
      assert {:ok, 1} = Streams.xlen(conn, k)
      assert {:ok, [{^id, %{"f" => "v"}}]} = Streams.xrange(conn, k)
    end

    test "geo", %{conn: conn, prefix: p} do
      k = key(p, "geo")

      assert {:ok, 2} =
               Geo.geoadd(conn, k, [
                 {13.361389, 38.115556, "Palermo"},
                 {15.087269, 37.502669, "Catania"}
               ])

      assert {:ok, dist} = Geo.geodist(conn, k, "Palermo", "Catania", :km)
      assert_in_delta dist, 166.27, 0.5
    end

    test "expiry", %{conn: conn, prefix: p} do
      k = key(p, "exp")
      assert {:ok, "OK"} = Strings.set(conn, k, "v", px: 400)
      assert {:ok, ttl} = HotKV.Keys.pttl(conn, k)
      assert ttl in 1..400
      assert {:ok, "v"} = Strings.get(conn, k)
      wait_until(fn -> Strings.get(conn, k) == {:ok, nil} end, 30)

      k2 = key(p, "exp2")
      Strings.set(conn, k2, "v")
      assert {:ok, true} = HotKV.Keys.expire(conn, k2, 100)
      assert {:ok, ttl2} = HotKV.Keys.ttl(conn, k2)
      assert ttl2 in 95..100
      assert {:ok, true} = HotKV.Keys.persist(conn, k2)
      assert {:ok, -1} = HotKV.Keys.ttl(conn, k2)
    end

    test "pipeline", %{conn: conn, prefix: p} do
      k = key(p, "pipe")

      assert {:ok, [{:ok, "OK"}, {:ok, 2}, {:ok, "2"}, {:error, %HotKV.Error{kind: :server}}]} =
               HotKV.pipeline(conn, [
                 ["SET", k, "1"],
                 ["INCR", k],
                 ["GET", k],
                 ["LPUSH", k, "x"]
               ])
    end

    test "MULTI/EXEC and WATCH", %{conn: conn, prefix: p} do
      k = key(p, "tx")

      {:ok, c} =
        HotKV.start_link(
          host: host(),
          port: port(),
          password: password(),
          tls: true,
          tls_opts: [ca_file: ca()]
        )

      assert {:ok, ["OK", 1, "1"]} =
               HotKV.transaction(c, fn t ->
                 HotKV.command(t, ["SET", k, "0"])
                 HotKV.command(t, ["INCR", k])
                 HotKV.command(t, ["GET", k])
               end)

      # an optimistic-lock abort: another connection changes the watched key
      assert {:ok, "OK"} = HotKV.watch(c, [k])
      assert {:ok, "OK"} = Strings.set(conn, k, "changed")

      assert {:ok, nil} =
               HotKV.transaction(c, fn t ->
                 HotKV.command(t, ["SET", k, "from-tx"])
               end)

      assert {:ok, "changed"} = Strings.get(conn, k)
    end

    test "a 1 MB binary value round-trips byte for byte", %{conn: conn, prefix: p} do
      k = key(p, "big")
      # random bytes, including CR LF and NUL, exactly 1 MiB
      value = :crypto.strong_rand_bytes(1_048_576 - 6) <> <<0, 13, 10, 255, 13, 10>>
      assert byte_size(value) == 1_048_576
      assert {:ok, "OK"} = Strings.set(conn, k, value)
      assert {:ok, 1_048_576} = Strings.strlen(conn, k)
      assert {:ok, ^value} = Strings.get(conn, k)
    end
  end

  # -- pub/sub, reconnect, concurrency ------------------------------------------

  describe "pub/sub, reconnect and concurrency" do
    test "pub/sub with separate connections", %{conn: conn, prefix: p} do
      {:ok, ps} =
        PubSub.start_link(
          host: host(),
          port: port(),
          password: password(),
          tls: true,
          tls_opts: [ca_file: ca()]
        )

      ch = key(p, "chan")
      pat = key(p, "pchan") <> ".*"

      :ok = PubSub.subscribe(ps, [ch])
      :ok = PubSub.psubscribe(ps, [pat])

      assert {:ok, 1} = HotKV.Channels.publish(conn, ch, "hello over TLS")

      assert_receive {:hotkv_pubsub, ^ps, :message, %{channel: ^ch, payload: "hello over TLS"}},
                     5_000

      pchan = String.replace_suffix(pat, ".*", ".news")
      assert {:ok, 1} = HotKV.Channels.publish(conn, pchan, "pattern hit")

      assert_receive {:hotkv_pubsub, ^ps, :pmessage,
                      %{pattern: ^pat, channel: ^pchan, payload: "pattern hit"}},
                     5_000

      big = :crypto.strong_rand_bytes(200_000)
      assert {:ok, 1} = HotKV.Channels.publish(conn, ch, big)
      assert_receive {:hotkv_pubsub, ^ps, :message, %{payload: ^big}}, 5_000
    end

    test "the connection recovers after the server closes it", %{conn: conn, prefix: p} do
      victim = connect_opts()
      k = key(p, "reconnect")
      assert {:ok, "OK"} = Strings.set(victim, k, "before")
      assert {:ok, id} = Server.client_id(victim)

      # a second connection closes only this client's connection
      assert {:ok, 1} = HotKV.command(conn, ["CLIENT", "KILL", "ID", id])

      wait_until(fn -> Strings.get(victim, k) == {:ok, "before"} end, 100)
      assert {:ok, "OK"} = Strings.set(victim, k, "after")
      assert {:ok, "after"} = Strings.get(conn, k)
    end

    test "many processes share a pool concurrently", %{prefix: p} do
      {:ok, pool} =
        HotKV.Pool.start_link(
          host: host(),
          port: port(),
          password: password(),
          tls: true,
          tls_opts: [ca_file: ca()],
          size: 4
        )

      results =
        1..60
        |> Task.async_stream(
          fn i ->
            k = key(p, "conc#{i}")
            {:ok, "OK"} = Strings.set(pool, k, "v#{i}")
            {:ok, 1} = HotKV.command(pool, ["INCR", k <> ":n"])
            {:ok, v} = Strings.get(pool, k)
            v == "v#{i}"
          end,
          max_concurrency: 30,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results)
      HotKV.Pool.stop(pool)
    end

    test "many in-flight commands on one connection", %{conn: conn, prefix: p} do
      k = key(p, "inflight")

      tasks =
        for i <- 1..100, do: Task.async(fn -> Lists.rpush(conn, k, Integer.to_string(i)) end)

      assert Enum.all?(Task.await_many(tasks, 30_000), &match?({:ok, _}, &1))
      assert {:ok, 100} = Lists.llen(conn, k)
    end
  end

  # -- licensed AI features through the typed API ------------------------------

  describe "AI and enterprise features (the server is licensed)" do
    test "SCACHE: create, set with an embedding, a similar get, stats, drop", %{
      conn: conn,
      prefix: p
    } do
      n = ns(p, "scache")
      assert {:ok, "OK"} = SemanticCache.create(conn, n, 3, threshold: 0.8)

      assert {:ok, "OK"} =
               SemanticCache.set(conn, n, "capital of france", "Paris", [1.0, 0.0, 0.0])

      assert {:ok, {"Paris", sim}} = SemanticCache.get(conn, n, [0.99, 0.01, 0.0])
      assert sim > 0.99
      assert {:ok, nil} = SemanticCache.get(conn, n, [0.0, 0.0, 1.0])
      assert {:ok, stats} = SemanticCache.stats(conn, n)
      assert stats["entries"] == 1 and stats["hits"] >= 1
      assert {:ok, true} = SemanticCache.drop(conn, n)
    end

    test "the get-or-call helpers call the model once", %{conn: conn, prefix: p} do
      sc = HotKV.AI.SemanticCache.new(conn, ns(p, "ai-sc"), ttl: 600)
      assert :ok = HotKV.AI.SemanticCache.create_namespace(sc, 3, threshold: 0.8)
      calls = :counters.new(1, [])

      llm = fn ->
        :counters.add(calls, 1, 1) &&
          {:ok, "an answer", %{model: "claude-sonnet-5", input_tokens: 8}}
      end

      assert {:ok, "an answer", false} =
               HotKV.AI.SemanticCache.get_or_call(sc, "q", [1.0, 0.0, 0.0], llm)

      assert {:ok, "an answer", true} =
               HotKV.AI.SemanticCache.get_or_call(sc, "q?", [0.99, 0.01, 0.0], llm)

      assert :counters.get(calls, 1) == 1
      SemanticCache.drop(conn, sc.ns)

      pc = HotKV.AI.PromptCache.new(conn, ns(p, "ai-pc"), ttl: 600)
      assert :ok = HotKV.AI.PromptCache.create_namespace(pc)
      input = %{provider: "openai", model: "gpt-4", messages: [%{role: "user", content: "2+2?"}]}

      llm2 = fn ->
        :counters.add(calls, 1, 1) &&
          {:ok, "4", %{model: "gpt-4", input_tokens: 5, output_tokens: 1}}
      end

      assert {:ok, "4", false} = HotKV.AI.PromptCache.get_or_call(pc, input, llm2)
      assert {:ok, "4", true} = HotKV.AI.PromptCache.get_or_call(pc, input, llm2)
      assert :counters.get(calls, 1) == 2
      PromptCache.drop(conn, pc.ns)
    end

    test "PCACHE with token usage", %{conn: conn, prefix: p} do
      n = ns(p, "pcache")
      assert {:ok, "OK"} = PromptCache.create(conn, n, max_entries: 100)
      usage = TokenUsage.new("claude-sonnet-5", input_tokens: 120, output_tokens: 40)
      assert {:ok, "OK"} = PromptCache.set(conn, n, "prompt", "response", usage: usage)
      assert {:ok, "response"} = PromptCache.get(conn, n, "prompt")
      assert {:ok, nil} = PromptCache.get(conn, n, "other prompt")
      assert {:ok, stats} = PromptCache.stats(conn, n)
      assert stats["usage_saved_requests"] == 1 and stats["usage_saved_input_tokens"] == 120
      assert {:ok, true} = PromptCache.drop(conn, n)
    end

    for {mod, label} <- [
          {ToolCache, "TOOL.CACHE"},
          {NegativeCache, "NCACHE"},
          {GuardCache, "GUARD"},
          {RerankCache, "RERANK"}
        ] do
      test "#{label} keyed cache", %{conn: conn, prefix: p} do
        mod = unquote(mod)
        n = ns(p, "kc")
        assert {:ok, "OK"} = mod.create(conn, n)
        assert {:ok, "OK"} = mod.set(conn, n, "k", "v")
        assert {:ok, "v"} = mod.get(conn, n, "k")
        assert {:ok, nil} = mod.get(conn, n, "absent")
        assert {:ok, %{"entries" => 1}} = mod.stats(conn, n)
        assert {:ok, true} = mod.del(conn, n, "k")
        assert {:ok, true} = mod.drop(conn, n)
      end
    end

    test "LLMBUDGET with float limits", %{conn: conn, prefix: p} do
      n = ns(p, "budget")
      assert {:ok, "OK"} = LLMBudget.set(conn, n, 10_000, 1.0e-5, 3600)
      assert {:ok, %{"cost_limit_usd" => "0.000010"}} = LLMBudget.status(conn, n)
      assert {:ok, "OK"} = LLMBudget.set(conn, n, 10_000, 12.5, 3600)

      assert {:ok, %{"cost_limit_usd" => "12.500000", "token_limit" => 10_000}} =
               LLMBudget.status(conn, n)

      assert {:ok, true} = LLMBudget.consume(conn, n, 100, 0.05)
      assert {:ok, false} = LLMBudget.consume(conn, n, 20_000, 0.0)
      assert {:ok, %{"tokens_used" => 100}} = LLMBudget.status(conn, n)
      assert {:ok, true} = LLMBudget.drop(conn, n)
    end

    test "LLMSTATS", %{conn: conn, prefix: p} do
      b = ns(p, "llmstats")
      assert {:ok, "OK"} = LLMStats.bucket(conn, b)
      assert {:ok, "OK"} = LLMStats.record(conn, b, 100, 50, 0, 0.0001, 250)
      assert {:ok, %{"requests" => 1, "input_tokens" => 100}} = LLMStats.get(conn, b)
      assert {:ok, true} = LLMStats.drop(conn, b)
    end

    test "PROMPT registry", %{conn: conn, prefix: p} do
      n = ns(p, "prompt")
      assert {:ok, 1} = PromptRegistry.put(conn, n, "You are helpful.")
      assert {:ok, 2} = PromptRegistry.put(conn, n, "You are very helpful.")
      assert {:ok, %{version: 1, content: "You are helpful."}} = PromptRegistry.get(conn, n, 1)
      assert {:ok, [1, 2]} = PromptRegistry.versions(conn, n)
      assert {:ok, true} = PromptRegistry.drop(conn, n)
    end

    test "EMBED.DEDUP", %{conn: conn, prefix: p} do
      n = ns(p, "dedup")
      blob = :crypto.strong_rand_bytes(64)
      assert {:ok, true} = EmbedDedup.put(conn, n, "hash1", "text-embedding-3", blob)
      assert {:ok, false} = EmbedDedup.put(conn, n, "hash1", "text-embedding-3", blob)
      assert {:ok, ^blob} = EmbedDedup.get(conn, n, "hash1")
      assert {:ok, true} = EmbedDedup.drop(conn, n)
    end

    test "AMEM: conversation, semantic, working, episodic memory", %{conn: conn, prefix: p} do
      session = ns(p, "amem")
      assert {:ok, "OK"} = AgentMemory.conv_create(conn, session, window: 10)
      assert {:ok, "OK"} = AgentMemory.conv_append(conn, session, "user", "hi")
      assert {:ok, "OK"} = AgentMemory.conv_append(conn, session, "assistant", "hello")

      assert {:ok, [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]} =
               AgentMemory.conv_get(conn, session)

      assert {:ok, true} = AgentMemory.conv_drop(conn, session)

      agent = ns(p, "amem-sem")
      assert {:ok, "OK"} = AgentMemory.sem_create(conn, agent, 3)

      assert {:ok, "OK"} =
               AgentMemory.sem_store(conn, agent, "fact1", "the sky is blue", [1.0, 0.0, 0.0])

      assert {:ok, [%{key: "fact1", content: "the sky is blue", similarity: sim}]} =
               AgentMemory.sem_recall(conn, agent, 3, [1.0, 0.0, 0.0])

      assert sim > 0.99
      assert {:ok, "OK"} = AgentMemory.work_set(conn, agent, "scratch", "v")
      assert {:ok, "v"} = AgentMemory.work_get(conn, agent, "scratch")

      assert {:ok, "OK"} =
               AgentMemory.epis_log(conn, agent, "tool_call", "did a thing", ~s({"ok":true}))

      assert {:ok, [%{type: "tool_call"}]} = AgentMemory.epis_query(conn, agent)
      assert {:ok, results} = AgentMemory.search(conn, agent, 5, [1.0, 0.0, 0.0])
      assert Enum.any?(results, &(&1.key == "fact1"))
      AgentMemory.work_clear(conn, agent)
      AgentMemory.epis_clear(conn, agent)
      assert {:ok, true} = AgentMemory.sem_forget(conn, agent, "fact1")
    end

    test "RAG pipeline", %{conn: conn, prefix: p} do
      n = ns(p, "rag")
      assert {:ok, "OK"} = RAG.create(conn, n, 3, chunk_size: 100)

      assert {:ok, chunks} =
               RAG.ingest(conn, n, "doc1", "hello world", vectors: [[1.0, 0.0, 0.0]])

      assert chunks >= 1
      assert {:ok, results} = RAG.search(conn, n, "hello", k: 3, vector: [1.0, 0.0, 0.0])
      assert Enum.any?(results, &(&1.doc_id == "doc1"))
      assert {:ok, "OK"} = RAG.drop(conn, n)
    end

    test "RATELIMIT and GCRA", %{conn: conn, prefix: p} do
      n = ns(p, "rl")
      assert {:ok, "OK"} = RateLimit.create(conn, n, 2, 60_000)
      assert {:ok, %{allowed: true}} = RateLimit.check(conn, n, "user1")
      assert {:ok, %{allowed: true}} = RateLimit.check(conn, n, "user1")
      assert {:ok, %{allowed: false}} = RateLimit.check(conn, n, "user1")
      assert {:ok, "OK"} = RateLimit.drop(conn, n)

      n2 = ns(p, "rl-bucket")
      assert {:ok, "OK"} = RateLimit.create(conn, n2, 5, 1_000, algo: :token_bucket, refill: 0.5)
      assert {:ok, %{allowed: true}} = RateLimit.check(conn, n2, "u")
      assert {:ok, "OK"} = RateLimit.drop(conn, n2)

      g = key(p, "gcra")
      assert {:ok, %{denied: false, limit: _}} = Gcra.limit(conn, g, 1_000, 2)
      assert {:ok, %{denied: false}} = Gcra.limit(conn, g, 1_000, 2)
      assert {:ok, %{denied: true}} = Gcra.limit(conn, g, 1_000, 2)
      assert {:ok, 1} = Gcra.reset(conn, g)
    end

    test "TS time series", %{conn: conn, prefix: p} do
      k = key(p, "ts")
      assert {:ok, "OK"} = TimeSeries.create(conn, k, labels: ["sensor", "elixir-remote"])
      assert {:ok, t1} = TimeSeries.add(conn, k, "*", 1.5)
      assert {:ok, t2} = TimeSeries.add(conn, k, t1 + 1, 1.0e-5)
      assert {:ok, [{^t1, 1.5}, {^t2, 1.0e-5}]} = TimeSeries.range(conn, k, "-", "+")
      assert {:ok, "OK"} = TimeSeries.delete(conn, k)
    end

    test "FEATURE store", %{conn: conn, prefix: p} do
      g = ns(p, "feature")

      assert {:ok, "OK"} =
               FeatureStore.create(conn, g, "user features", [
                 {"age", "int64"},
                 {"score", "double"}
               ])

      assert {:ok, "OK"} = FeatureStore.set(conn, g, "user1", [{"age", "30"}, {"score", "1.5"}])
      assert {:ok, %{features: %{"age" => 30}}} = FeatureStore.get(conn, g, "user1")

      assert {:ok, [%{features: %{"age" => 30}}, nil]} =
               FeatureStore.batch(conn, g, ["user1", "nobody"])

      assert {:ok, "OK"} = FeatureStore.drop(conn, g)
    end

    test "VSIM vector index", %{conn: conn, prefix: p} do
      idx = ns(p, "vsim")
      assert {:ok, "OK"} = Vsim.createindex(conn, idx, 3, metric: :cosine)
      assert {:ok, true} = Vsim.set(conn, idx, "a", [1.0, 0.0, 0.0])
      assert {:ok, true} = Vsim.set(conn, idx, "b", [0.0, 1.0, 0.0])
      assert {:ok, [{"a", d1}, {"b", d2}]} = Vsim.search(conn, idx, 2, [0.9, 0.1, 0.0])
      assert d1 < d2
      assert {:ok, [1.0, +0.0, +0.0]} = Vsim.get(conn, idx, "a")
      assert {:ok, "OK"} = Vsim.dropindex(conn, idx)
    end
  end
end

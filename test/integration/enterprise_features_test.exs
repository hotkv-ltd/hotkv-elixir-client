# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.EnterpriseFeaturesIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  # Every command family in this file needs a server license that includes
  # the matching feature. Against a server without it the commands reply
  # NOLICENSE; each test below detects that via
  # HotKV.TestSupport.licensed_or_skip/2 and passes with a printed skip
  # reason instead of failing. Against a licensed server, the same test
  # exercises the real behavior end to end.

  alias HotKV.{
    Alerts,
    FeatureStore,
    Observe,
    RAG,
    RateLimit,
    SemanticCache,
    TestSupport,
    TimeSeries
  }

  alias HotKV.AgentMemory

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  describe "HotKV.SemanticCache (SCACHE.*)" do
    test "CREATE/SET/GET/STATS/THRESHOLD/FLUSH/DROP/LIST", %{conn: conn} do
      ns = TestSupport.unique("scache")

      SemanticCache.create(conn, ns, 3, threshold: 0.5)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} =
                 SemanticCache.set(conn, ns, "what color is the sky", "blue", [1.0, 0.0, 0.0])

        assert {:ok, {"blue", similarity}} = SemanticCache.get(conn, ns, [1.0, 0.0, 0.0])
        assert similarity >= 0.99
        assert {:ok, nil} = SemanticCache.get(conn, ns, [0.0, 0.0, 1.0])
        assert {:ok, stats} = SemanticCache.stats(conn, ns)
        assert stats["entries"] == 1
        assert {:ok, "OK"} = SemanticCache.threshold(conn, ns, 0.9)
        assert {:ok, names} = SemanticCache.list(conn)
        assert ns in names
        assert {:ok, true} = SemanticCache.flush(conn, ns)
        assert {:ok, true} = SemanticCache.drop(conn, ns)
      end)
    end

    test "SET with usage attributes usage_saved_* stats on a later hit", %{conn: conn} do
      ns = TestSupport.unique("scache:usage")

      SemanticCache.create(conn, ns, 3, threshold: 0.5)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        usage = HotKV.TokenUsage.new("claude-sonnet-5", input_tokens: 100, output_tokens: 20)

        assert {:ok, "OK"} =
                 SemanticCache.set(conn, ns, "what color is the sky", "blue", [1.0, 0.0, 0.0],
                   usage: usage
                 )

        assert {:ok, {"blue", _similarity}} = SemanticCache.get(conn, ns, [1.0, 0.0, 0.0])
        assert {:ok, stats} = SemanticCache.stats(conn, ns)
        assert stats["usage_saved_requests"] == 1
        assert stats["usage_saved_input_tokens"] == 100
      end)
    end
  end

  describe "HotKV.AgentMemory (AMEM.*)" do
    test "conversation memory: CREATE/APPEND/GET/WINDOW/CLEAR/DROP", %{conn: conn} do
      session = TestSupport.unique("amem:conv")

      AgentMemory.conv_create(conn, session, window: 10)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} = AgentMemory.conv_append(conn, session, "user", "hi")
        assert {:ok, "OK"} = AgentMemory.conv_append(conn, session, "assistant", "hello")

        assert {:ok, [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]} =
                 AgentMemory.conv_get(conn, session)

        assert {:ok, [%{role: "assistant", content: "hello"}]} =
                 AgentMemory.conv_window(conn, session, 1)

        assert {:ok, true} = AgentMemory.conv_clear(conn, session)
        assert {:ok, true} = AgentMemory.conv_drop(conn, session)
      end)
    end

    test "semantic memory: CREATE/STORE/RECALL/FORGET/LIST", %{conn: conn} do
      agent = TestSupport.unique("amem:sem")

      AgentMemory.sem_create(conn, agent, 3)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} =
                 AgentMemory.sem_store(conn, agent, "fact1", "the sky is blue", [1.0, 0.0, 0.0])

        assert {:ok, [%{key: "fact1", content: "the sky is blue", similarity: sim}]} =
                 AgentMemory.sem_recall(conn, agent, 5, [1.0, 0.0, 0.0])

        assert sim >= 0.99
        assert {:ok, ["fact1"]} = AgentMemory.sem_list(conn, agent)
        assert {:ok, true} = AgentMemory.sem_forget(conn, agent, "fact1")
      end)
    end

    test "working memory: SET/GET/DEL/CLEAR/LIST", %{conn: conn} do
      session = TestSupport.unique("amem:work")

      AgentMemory.work_set(conn, session, "scratch", "value")
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "value"} = AgentMemory.work_get(conn, session, "scratch")
        assert {:ok, ["scratch"]} = AgentMemory.work_list(conn, session)
        assert {:ok, true} = AgentMemory.work_del(conn, session, "scratch")
        assert {:ok, nil} = AgentMemory.work_get(conn, session, "scratch")
      end)
    end

    test "episodic memory: LOG/QUERY/STATS/CLEAR", %{conn: conn} do
      agent = TestSupport.unique("amem:epis")

      AgentMemory.epis_log(conn, agent, "tool_call", "did a thing", ~s({"ok":true}))
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, [%{type: "tool_call", content: "did a thing"}]} =
                 AgentMemory.epis_query(conn, agent)

        assert {:ok, %{"total_events" => 1}} = AgentMemory.epis_stats(conn, agent)
        assert {:ok, true} = AgentMemory.epis_clear(conn, agent)
      end)
    end

    test "cross-memory SEARCH combines semantic, episodic and working memory", %{conn: conn} do
      agent = TestSupport.unique("amem:search")

      AgentMemory.sem_create(conn, agent, 3)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        AgentMemory.sem_store(conn, agent, "fact1", "paris is the capital of france", [
          1.0,
          0.0,
          0.0
        ])

        assert {:ok, results} = AgentMemory.search(conn, agent, 5, [1.0, 0.0, 0.0])
        assert Enum.any?(results, &(&1.key == "fact1"))
      end)
    end

    test "AMEM.SUMMARY.* needs the summary license feature", %{conn: conn} do
      agent = TestSupport.unique("amem:summary")

      AgentMemory.summary_set(conn, agent, "initial summary")
      |> TestSupport.licensed_or_skip(fn {:ok, version} ->
        assert version >= 1
        assert {:ok, %{summary: "initial summary"}} = AgentMemory.summary_get(conn, agent)
        assert {:ok, _} = AgentMemory.summary_append(conn, agent, " and more")
        assert {:ok, names} = AgentMemory.summary_list(conn)
        assert agent in names
        assert {:ok, true} = AgentMemory.summary_drop(conn, agent)
      end)
    end
  end

  describe "HotKV.RAG (RAG.*)" do
    test "CREATE/INGEST/SEARCH/STATS/DROP/LIST", %{conn: conn} do
      pipeline = TestSupport.unique("rag")

      RAG.create(conn, pipeline, 3, chunk_size: 100)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, chunks} =
                 RAG.ingest(conn, pipeline, "doc1", "hello world", vectors: [[1.0, 0.0, 0.0]])

        assert chunks >= 1

        assert {:ok, results} = RAG.search(conn, pipeline, "hello", k: 5, vector: [1.0, 0.0, 0.0])
        assert Enum.any?(results, &(&1.doc_id == "doc1"))

        assert {:ok, stats} = RAG.stats(conn, pipeline)
        assert stats["totalDocs"] >= 1

        assert {:ok, names} = RAG.list(conn)
        assert pipeline in names
        assert {:ok, "OK"} = RAG.drop(conn, pipeline)
      end)
    end
  end

  describe "HotKV.RateLimit (RATELIMIT.*)" do
    test "CREATE/CHECK/PEEK/STATS/RESET/DROP/LIST", %{conn: conn} do
      name = TestSupport.unique("ratelimit")
      key = "user1"

      RateLimit.create(conn, name, 2, 60_000)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, %{allowed: true}} = RateLimit.check(conn, name, key)
        assert {:ok, %{allowed: true}} = RateLimit.check(conn, name, key)
        assert {:ok, %{allowed: false}} = RateLimit.check(conn, name, key)
        assert {:ok, %{allowed: false}} = RateLimit.peek(conn, name, key)

        assert {:ok, stats} = RateLimit.stats(conn, name)
        assert stats["limit"] == 2

        assert {:ok, "OK"} = RateLimit.reset(conn, name, key)
        assert {:ok, names} = RateLimit.list(conn)
        assert name in names
        assert {:ok, "OK"} = RateLimit.drop(conn, name)
      end)
    end
  end

  describe "HotKV.TimeSeries (TS.*)" do
    test "CREATE/ADD/RANGE/AGG/INFO/RETENTION/DOWNSAMPLE/LIST/DELETE", %{conn: conn} do
      key = TestSupport.unique("ts")
      dest = key <> ":down"

      TimeSeries.create(conn, key, labels: ["sensor", "a"])
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} = TimeSeries.create(conn, dest)

        assert {:ok, t1} = TimeSeries.add(conn, key, "*", 1.0)
        assert {:ok, t2} = TimeSeries.add(conn, key, t1 + 1, 2.0)

        assert {:ok, [{^t1, 1.0}, {^t2, 2.0}]} = TimeSeries.range(conn, key, "-", "+")
        assert {:ok, [{_, avg}]} = TimeSeries.agg(conn, key, "-", "+", 100_000, :avg)
        assert_in_delta avg, 1.5, 0.01

        assert {:ok, info} = TimeSeries.info(conn, key)
        assert info["totalSamples"] == 2
        assert info["labels"] == %{"sensor" => "a"}

        assert {:ok, "OK"} = TimeSeries.retention(conn, key, 3_600_000)
        assert {:ok, "OK"} = TimeSeries.downsample(conn, key, dest, :avg, 60_000)

        assert {:ok, names} = TimeSeries.list(conn, {"sensor", "a"})
        assert key in names

        assert {:ok, "OK"} = TimeSeries.delete(conn, dest)
        assert {:ok, "OK"} = TimeSeries.delete(conn, key)
      end)
    end
  end

  describe "HotKV.FeatureStore (FEATURE.*)" do
    test "CREATE/SET/GET/BATCH/SCHEMA/STATS/LIST/DROP", %{conn: conn} do
      group = TestSupport.unique("feature")

      FeatureStore.create(conn, group, "user features", [
        {"age", "int64"},
        {"score", "double"}
      ])
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} =
                 FeatureStore.set(conn, group, "user1", [{"age", "30"}, {"score", "1.5"}])

        assert {:ok, %{features: features}} = FeatureStore.get(conn, group, "user1")
        # int64/double schema fields come back server-typed: a native integer
        # for "age" (int64), a formatted decimal string for "score" (double).
        assert features["age"] == 30
        assert {:ok, nil} = FeatureStore.get(conn, group, "no-such-user")

        assert {:ok, [entry, nil]} = FeatureStore.batch(conn, group, ["user1", "no-such-user"])
        assert entry.features["age"] == 30

        assert {:ok, schema} = FeatureStore.schema(conn, group)
        assert {"age", _} = Enum.find(schema, fn {name, _} -> name == "age" end)

        assert {:ok, stats} = FeatureStore.stats(conn, group)
        assert stats["entities"] == 1

        assert {:ok, names} = FeatureStore.list(conn)
        assert group in names
        assert {:ok, "OK"} = FeatureStore.drop(conn, group)
      end)
    end
  end

  describe "HotKV.Observe and HotKV.Alerts (OBSERVE/ALERTS, admin)" do
    test "OBSERVE INFO/METRICS", %{conn: conn} do
      Observe.info(conn)
      |> TestSupport.licensed_or_skip(fn {:ok, info} ->
        assert is_integer(info["connected_clients"])
        assert {:ok, metrics} = Observe.metrics(conn)
        assert is_integer(metrics["total_commands"])
      end)
    end

    test "ALERTS INFO/SETURL/SETSEVERITY/ON/OFF/TEST", %{conn: conn} do
      Alerts.info(conn)
      |> TestSupport.licensed_or_skip(fn {:ok, info} ->
        assert info["provider"] in ["slack", "discord", "telegram", "generic"]

        assert {:ok, _} = Alerts.setseverity(conn, :warning)
        assert {:ok, _} = Alerts.off(conn)
        assert {:ok, _} = Alerts.on(conn)
        assert {:ok, _} = Alerts.seturl(conn, "")

        case Alerts.test(conn, :info, ["integration", "test"]) do
          {:ok, message} -> assert String.starts_with?(message, "OK")
          {:error, %HotKV.Error{kind: :server}} -> :ok
        end
      end)
    end
  end
end

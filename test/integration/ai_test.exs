# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AIIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  alias HotKV.AI.{PromptCache, SemanticCache}
  alias HotKV.TestSupport

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  describe "HotKV.AI.SemanticCache (backed by SCACHE.*, needs the semantic-cache license feature)" do
    test "calls the LLM only on a miss, and serves a hit from cache afterward", %{conn: conn} do
      ns = TestSupport.unique("ai:scache")
      sc = SemanticCache.new(conn, ns, ttl: 3600)

      SemanticCache.create_namespace(sc, 3, threshold: 0.8)
      |> TestSupport.licensed_or_skip(fn :ok ->
        call_count = :counters.new(1, [])

        llm = fn ->
          :counters.add(call_count, 1, 1)
          {:ok, "Paris is the capital of France.", %{model: "claude-sonnet-5", input_tokens: 8}}
        end

        assert {:ok, "Paris is the capital of France.", false} =
                 SemanticCache.get_or_call(sc, "capital of france", [1.0, 0.0, 0.0], llm)

        assert :counters.get(call_count, 1) == 1

        # A near-identical embedding should now hit the cache: the LLM must
        # not be called a second time.
        assert {:ok, "Paris is the capital of France.", true} =
                 SemanticCache.get_or_call(sc, "capital of france?", [0.99, 0.01, 0.0], llm)

        assert :counters.get(call_count, 1) == 1
        assert {:ok, stats} = SemanticCache.stats(sc)
        assert stats["usage_saved_requests"] == 1
      end)
    end

    test "calling create_namespace/3 twice is not an error", %{conn: conn} do
      ns = TestSupport.unique("ai:scache:dup")
      sc = SemanticCache.new(conn, ns)

      SemanticCache.create_namespace(sc, 2)
      |> TestSupport.licensed_or_skip(fn :ok ->
        assert :ok = SemanticCache.create_namespace(sc, 2)
      end)
    end

    test "an unavailable cache (NOLICENSE) still calls through instead of failing the request", %{
      conn: conn
    } do
      ns = TestSupport.unique("ai:scache:unlicensed")
      sc = SemanticCache.new(conn, ns)

      case HotKV.SemanticCache.create(conn, ns, 3) do
        {:error, %HotKV.Error{kind: :not_licensed}} ->
          assert {:ok, "called", false} =
                   SemanticCache.get_or_call(sc, "q", [1.0, 0.0, 0.0], fn -> {:ok, "called"} end)

        {:ok, "OK"} ->
          # The license includes the feature after all: this scenario does not
          # apply, but the helper must still work normally.
          assert {:ok, "called", false} =
                   SemanticCache.get_or_call(sc, "q", [1.0, 0.0, 0.0], fn -> {:ok, "called"} end)
      end
    end
  end

  describe "HotKV.AI.PromptCache (backed by PCACHE.*, needs the prompt-cache license feature)" do
    test "calls the LLM only on a miss, and records usage via LLMSTATS when configured", %{
      conn: conn
    } do
      ns = TestSupport.unique("ai:pcache")

      pc =
        PromptCache.new(conn, ns, ttl: 3600, stats_bucket: TestSupport.unique("ai:pcache:stats"))

      PromptCache.create_namespace(pc)
      |> TestSupport.licensed_or_skip(fn :ok ->
        call_count = :counters.new(1, [])

        input = %{
          provider: "openai",
          model: "gpt-4",
          messages: [%{role: "user", content: "2+2?"}]
        }

        llm = fn ->
          :counters.add(call_count, 1, 1)

          {:ok, "4",
           %{model: "gpt-4", input_tokens: 5, output_tokens: 1, cost_usd: 0.0001, latency_ms: 12}}
        end

        assert {:ok, "4", false} = PromptCache.get_or_call(pc, input, llm)
        assert :counters.get(call_count, 1) == 1
        assert {:ok, "4", true} = PromptCache.get_or_call(pc, input, llm)
        assert :counters.get(call_count, 1) == 1

        # The miss stored usage (via :model) with the entry, so the hit
        # above attributed it to this namespace's usage_saved_* stats.
        assert {:ok, stats} = PromptCache.stats(pc)
        assert stats["usage_saved_requests"] == 1
        assert stats["usage_saved_input_tokens"] == 5
      end)
    end

    test "an unavailable cache (NOLICENSE) still calls through instead of failing the request", %{
      conn: conn
    } do
      # Uses a PromptCache pointed at a namespace that was never created, so
      # without the feature PCACHE.GET itself replies NOLICENSE; get_or_call
      # must treat that as "cache unavailable", not as a request failure.
      ns = TestSupport.unique("ai:pcache:unlicensed")
      pc = PromptCache.new(conn, ns)
      input = %{provider: "p", model: "m", messages: [%{role: "user", content: "hi"}]}

      case HotKV.PromptCache.create(conn, ns) do
        {:error, %HotKV.Error{kind: :not_licensed}} ->
          assert {:ok, "called", false} =
                   PromptCache.get_or_call(pc, input, fn -> {:ok, "called", %{}} end)

        {:ok, "OK"} ->
          # The license includes the feature after all: this scenario does not
          # apply, but the helper must still work normally.
          assert {:ok, "called", false} =
                   PromptCache.get_or_call(pc, input, fn -> {:ok, "called", %{}} end)
      end
    end
  end
end

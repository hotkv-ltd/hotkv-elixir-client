# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.EnterpriseLicensedIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag :integration

  # Every command family in this file needs a server license that includes
  # the matching feature. Against a server without it the commands reply
  # NOLICENSE; each test below detects that via
  # HotKV.TestSupport.licensed_or_skip/2 and passes with a printed skip
  # reason instead of failing. Against a licensed server, the very same
  # test exercises the real behavior end to end.

  alias HotKV.{
    EmbedDedup,
    GuardCache,
    LLMBudget,
    LLMPrice,
    LLMStats,
    NegativeCache,
    PromptCache,
    PromptRegistry,
    TokenUsage
  }

  alias HotKV.{RerankCache, TestSupport, ToolCache, Vsim}

  setup do
    {:ok, conn: TestSupport.start_conn()}
  end

  test "HotKV.PromptCache (PCACHE.*)", %{conn: conn} do
    ns = TestSupport.unique("pcache")

    PromptCache.create(conn, ns, max_entries: 100, cost_per_hit: 0.002)
    |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
      assert {:ok, "OK"} = PromptCache.set(conn, ns, "prompt1", "response1")
      assert {:ok, "response1"} = PromptCache.get(conn, ns, "prompt1")

      assert {:ok, %{response: "response1", hit_count: count}} =
               PromptCache.getex(conn, ns, "prompt1")

      assert count >= 1
      assert {:ok, stats} = PromptCache.stats(conn, ns)
      assert stats["entries"] == 1
      assert {:ok, "OK"} = PromptCache.config_set(conn, ns, :ttl, 3600)
      assert {:ok, names} = PromptCache.list(conn)
      assert ns in names
      assert {:ok, true} = PromptCache.del(conn, ns, "prompt1")
      assert {:ok, _flushed} = PromptCache.flush(conn, ns)
      assert {:ok, true} = PromptCache.drop(conn, ns)
    end)
  end

  test "HotKV.PromptCache SET with usage attributes usage_saved_* stats", %{conn: conn} do
    ns = TestSupport.unique("pcache:usage")

    PromptCache.create(conn, ns)
    |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
      usage = TokenUsage.new("claude-sonnet-5", input_tokens: 120, output_tokens: 40)
      assert {:ok, "OK"} = PromptCache.set(conn, ns, "prompt1", "response1", usage: usage)
      assert {:ok, "response1"} = PromptCache.get(conn, ns, "prompt1")
      assert {:ok, stats} = PromptCache.stats(conn, ns)
      assert stats["usage_saved_requests"] == 1
      assert stats["usage_saved_input_tokens"] == 120
      assert {:ok, true} = PromptCache.drop(conn, ns)
    end)
  end

  for {mod, name} <- [
        {ToolCache, "HotKV.ToolCache (TOOL.CACHE.*)"},
        {NegativeCache, "HotKV.NegativeCache (NCACHE.*)"},
        {GuardCache, "HotKV.GuardCache (GUARD.*)"},
        {RerankCache, "HotKV.RerankCache (RERANK.*)"}
      ] do
    test name, %{conn: conn} do
      mod = unquote(mod)
      ns = TestSupport.unique("keyedcache")

      mod.create(conn, ns)
      |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
        assert {:ok, "OK"} = mod.set(conn, ns, "k1", "v1")
        assert {:ok, "v1"} = mod.get(conn, ns, "k1")
        assert {:ok, stats} = mod.stats(conn, ns)
        assert stats["entries"] == 1

        usage = TokenUsage.new("claude-sonnet-5", input_tokens: 10, output_tokens: 2)
        assert {:ok, "OK"} = mod.set(conn, ns, "k2", "v2", usage: usage)
        assert {:ok, "v2"} = mod.get(conn, ns, "k2")
        assert {:ok, stats_after} = mod.stats(conn, ns)
        assert stats_after["usage_saved_requests"] == 1

        assert {:ok, names} = mod.list(conn)
        assert ns in names
        assert {:ok, true} = mod.del(conn, ns, "k1")
        assert {:ok, _flushed} = mod.flush(conn, ns)
        assert {:ok, true} = mod.drop(conn, ns)
      end)
    end
  end

  test "HotKV.LLMStats (LLMSTATS.*)", %{conn: conn} do
    bucket = TestSupport.unique("llmstats")

    LLMStats.bucket(conn, bucket)
    |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
      assert {:ok, "OK"} = LLMStats.record(conn, bucket, 100, 50, 0, 0.01, 250)
      assert {:ok, stats} = LLMStats.get(conn, bucket)
      assert stats["requests"] == 1

      model = TestSupport.unique("llmprice:model")
      assert {:ok, "OK"} = LLMStats.price_set(conn, model, 3, 15)
      assert {:ok, %LLMPrice{source: "custom"} = price} = LLMStats.price_get(conn, model)
      assert_in_delta price.input_usd_per_mtok, 3.0, 1.0e-6
      assert {:ok, list} = LLMStats.price_list(conn)
      assert Enum.any?(list, &(&1.model == model))

      assert {:ok, "OK"} = LLMStats.record(conn, bucket, 100, 50, 0, 0, 250, model: model)

      assert {:ok, %LLMPrice{source: "unpriced"}} = LLMStats.price_get(conn, "no-such-model")
      assert {:ok, true} = LLMStats.price_del(conn, model)
      assert {:ok, false} = LLMStats.price_del(conn, model)

      assert {:ok, true} = LLMStats.reset(conn, bucket)
      assert {:ok, names} = LLMStats.list(conn)
      assert bucket in names
      assert {:ok, true} = LLMStats.drop(conn, bucket)
    end)
  end

  test "HotKV.LLMBudget (LLMBUDGET.*)", %{conn: conn} do
    name = TestSupport.unique("llmbudget")

    LLMBudget.set(conn, name, 1000, 1.0, 3600)
    |> TestSupport.licensed_or_skip(fn {:ok, "OK"} ->
      assert {:ok, true} = LLMBudget.consume(conn, name, 100, 0.05)

      usage = TokenUsage.new("claude-sonnet-5", input_tokens: 100, output_tokens: 20)
      assert {:ok, true} = LLMBudget.consume(conn, name, 0, 0, usage)

      assert {:ok, status} = LLMBudget.status(conn, name)
      assert status["token_limit"] == 1000
      assert is_integer(status["unpriced_requests"])
      assert {:ok, true} = LLMBudget.reset(conn, name)
      assert {:ok, names} = LLMBudget.list(conn)
      assert name in names
      assert {:ok, true} = LLMBudget.drop(conn, name)
    end)
  end

  test "HotKV.PromptRegistry (PROMPT.*)", %{conn: conn} do
    name = TestSupport.unique("promptreg")

    PromptRegistry.put(conn, name, "You are a helpful assistant.")
    |> TestSupport.licensed_or_skip(fn {:ok, version} ->
      assert version == 1

      assert {:ok, %{version: 1, content: "You are a helpful assistant."}} =
               PromptRegistry.get(conn, name)

      assert {:ok, %{version: 1}} = PromptRegistry.latest(conn, name)
      assert {:ok, 2} = PromptRegistry.put(conn, name, "v2 content")
      assert {:ok, "OK"} = PromptRegistry.setactive(conn, name, 1)
      assert {:ok, [1, 2]} = PromptRegistry.versions(conn, name)
      assert {:ok, names} = PromptRegistry.list(conn)
      assert name in names
      assert {:ok, true} = PromptRegistry.drop(conn, name)
    end)
  end

  test "HotKV.EmbedDedup (EMBED.DEDUP.*)", %{conn: conn} do
    ns = TestSupport.unique("embeddedup")

    EmbedDedup.put(conn, ns, "hash1", "text-embedding-3", <<1, 2, 3, 4>>)
    |> TestSupport.licensed_or_skip(fn {:ok, true} ->
      assert {:ok, false} = EmbedDedup.put(conn, ns, "hash1", "text-embedding-3", <<1, 2, 3, 4>>)
      assert {:ok, <<1, 2, 3, 4>>} = EmbedDedup.get(conn, ns, "hash1")
      assert {:ok, stats} = EmbedDedup.stats(conn, ns)
      assert stats["entries"] == 1
      assert {:ok, true} = EmbedDedup.release(conn, ns, "hash1")
      assert {:ok, true} = EmbedDedup.purge(conn, ns)
      assert {:ok, names} = EmbedDedup.list(conn)
      assert ns in names
      assert {:ok, true} = EmbedDedup.drop(conn, ns)
    end)
  end

  test "HotKV.Vsim persistence (VSIM.SAVE/LOAD/LIST/DROP)", %{conn: conn} do
    # Snapshot names may not contain "/", "\\", "." or ":" (so not unique/1's colons).
    snapshot = "hkvtest_vsimsnap_#{System.unique_integer([:positive])}"

    Vsim.save(conn, snapshot, <<1, 2, 3>>)
    |> TestSupport.licensed_or_skip(fn {:ok, bytes} ->
      # the file is a 12 byte header plus the blob
      assert bytes == 12 + 3
      assert {:ok, <<1, 2, 3>>} = Vsim.load(conn, snapshot)
      assert {:ok, names} = Vsim.list_snapshots(conn)
      assert snapshot in names
      assert {:ok, true} = Vsim.drop_snapshot(conn, snapshot)
    end)
  end
end

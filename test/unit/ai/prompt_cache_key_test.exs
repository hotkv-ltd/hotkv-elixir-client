# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AI.PromptCacheKeyTest do
  use ExUnit.Case, async: true

  alias HotKV.AI.PromptCacheKey

  test "canonical_json/1 orders top-level keys and keeps message order" do
    input = %{
      provider: "openai",
      model: "gpt-4",
      system: "be nice",
      messages: [%{role: "system", content: "s"}, %{role: "user", content: "u"}],
      params: %{}
    }

    assert PromptCacheKey.canonical_json(input) ==
             ~s({"provider":"openai","model":"gpt-4","system":"be nice",) <>
               ~s("messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}],"params":{}})
  end

  test "missing system and params are still present, as \"\" and {}" do
    input = %{provider: "a", model: "b", messages: []}

    assert PromptCacheKey.canonical_json(input) ==
             ~s({"provider":"a","model":"b","system":"","messages":[],"params":{}})
  end

  test "params keys are sorted ascending by byte value" do
    input = %{
      provider: "a",
      model: "b",
      messages: [],
      params: %{"top_p" => "1", "max_tokens" => "256", "temperature" => "0.7"}
    }

    assert PromptCacheKey.canonical_json(input) ==
             ~s({"provider":"a","model":"b","system":"","messages":[],) <>
               ~s("params":{"max_tokens":"256","temperature":"0.7","top_p":"1"}})
  end

  test "compact encoding: no insignificant whitespace" do
    json = PromptCacheKey.canonical_json(%{provider: "a", model: "b", messages: []})
    refute json =~ ": "
    refute json =~ ", "
  end

  test "standard JSON string escaping for quotes, backslashes and control characters" do
    assert PromptCacheKey.json_string("a\"b\\c\n\t\r\b\f\x01") ==
             ~s("a\\"b\\\\c\\n\\t\\r\\b\\f\\u0001")
  end

  test "non-ASCII characters are left as literal UTF-8, not \\u escaped" do
    assert PromptCacheKey.json_string("café 中文") == "\"café 中文\""
  end

  test "accepts messages as {role, content} tuples or string-keyed maps too" do
    input = %{provider: "a", model: "b", messages: [{"user", "hi"}]}
    assert PromptCacheKey.canonical_json(input) =~ ~s("messages":[{"role":"user","content":"hi"}])

    input2 = %{provider: "a", model: "b", messages: [%{"role" => "user", "content" => "hi"}]}

    assert PromptCacheKey.canonical_json(input2) =~
             ~s("messages":[{"role":"user","content":"hi"}])
  end

  test "build/1 is the lowercase hex SHA-256 of canonical_json/1" do
    input = %{provider: "a", model: "b", messages: []}

    expected =
      :sha256 |> :crypto.hash(PromptCacheKey.canonical_json(input)) |> Base.encode16(case: :lower)

    assert PromptCacheKey.build(input) == expected
    assert String.length(PromptCacheKey.build(input)) == 64
    assert PromptCacheKey.build(input) == String.downcase(PromptCacheKey.build(input))
  end

  test "build/1 is deterministic for the same logical input" do
    input = %{
      provider: "anthropic",
      model: "claude-sonnet-5",
      messages: [%{role: "user", content: "hello"}],
      params: %{"temperature" => "0.7"}
    }

    assert PromptCacheKey.build(input) == PromptCacheKey.build(input)
  end

  test "build/1 differs when the logical input differs" do
    a = %{provider: "a", model: "m", messages: [%{role: "user", content: "hi"}]}
    b = %{provider: "a", model: "m", messages: [%{role: "user", content: "hi!"}]}
    refute PromptCacheKey.build(a) == PromptCacheKey.build(b)
  end

  test "matches an independently computed Python-style reference digest" do
    input = %{
      provider: "openai",
      model: "gpt-4",
      system: "You are helpful.",
      messages: [%{role: "user", content: "Hi \"there\"\n\tunicode: é中"}],
      params: %{"temperature" => "0.7", "top_p" => "1", "max_tokens" => "256"}
    }

    assert PromptCacheKey.build(input) ==
             "f052c822eb35479241e88fd149cee56ee797bc44b2aa83197f8cbaf4f50f6266"
  end
end

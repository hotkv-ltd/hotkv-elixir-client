# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.AI.PromptCacheKey do
  @moduledoc """
  The canonical `PromptCache` key derivation (shared by all official SDKs): a
  deterministic, compact, sorted-key JSON encoding of a chat-style LLM
  request, SHA-256 hashed to a lowercase hex string. Every official HotKV
  SDK implements this exact canonical form, so a key computed here matches
  the same key computed by any other SDK for the same logical request.

  No JSON library is used (and none is a dependency of this package): the
  canonical form is simple enough, and needs to be exact, so it is written
  directly.
  """

  @type message :: %{role: String.t(), content: String.t()} | {String.t(), String.t()}
  @type input :: %{
          optional(:provider) => String.t(),
          optional(:model) => String.t(),
          optional(:system) => String.t(),
          optional(:messages) => [message],
          optional(:params) => %{(String.t() | atom) => String.t()}
        }

  @doc """
  The cache key for `input`: the lowercase hex SHA-256 digest of
  `canonical_json/1`'s UTF-8 bytes.

  `input[:params]` must already be string-valued (format numbers yourself,
  e.g. `"0.7"`, not `0.7`, so float formatting never differs between
  languages or between runs).
  """
  @spec build(input) :: String.t()
  def build(input) do
    :sha256 |> :crypto.hash(canonical_json(input)) |> Base.encode16(case: :lower)
  end

  @doc """
  The canonical JSON string `build/1` hashes: keys in a fixed order
  (`provider`, `model`, `system`, `messages`, `params`), messages in the
  caller's given order, `params` keys sorted ascending by byte value,
  compact (no insignificant whitespace), standard JSON string escaping,
  non-ASCII characters left as literal UTF-8.
  """
  @spec canonical_json(input) :: String.t()
  def canonical_json(input) do
    provider = Map.get(input, :provider, "")
    model = Map.get(input, :model, "")
    system = Map.get(input, :system, "")
    messages = Map.get(input, :messages, [])
    params = Map.get(input, :params, %{})

    IO.iodata_to_binary([
      "{\"provider\":",
      json_string(provider),
      ",\"model\":",
      json_string(model),
      ",\"system\":",
      json_string(system),
      ",\"messages\":[",
      messages |> Enum.map(&message_json/1) |> Enum.intersperse(","),
      "],\"params\":{",
      params |> params_json() |> Enum.intersperse(","),
      "}}"
    ])
  end

  defp message_json(message) do
    {role, content} = message_fields(message)
    ["{\"role\":", json_string(role), ",\"content\":", json_string(content), "}"]
  end

  defp message_fields({role, content}), do: {role, content}
  defp message_fields(%{role: role, content: content}), do: {role, content}
  defp message_fields(%{"role" => role, "content" => content}), do: {role, content}

  defp params_json(params) do
    params
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> [json_string(k), ":", json_string(v)] end)
  end

  @doc false
  # Exposed for unit testing the escaper directly against known vectors.
  def json_string(str) when is_binary(str) do
    IO.iodata_to_binary(["\"", for(<<cp::utf8 <- str>>, into: "", do: escape(cp)), "\""])
  end

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\n), do: "\\n"
  defp escape(?\r), do: "\\r"
  defp escape(?\t), do: "\\t"
  defp escape(0x08), do: "\\b"
  defp escape(0x0C), do: "\\f"

  defp escape(cp) when cp < 0x20 do
    "\\u" <> (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  defp escape(cp), do: <<cp::utf8>>
end

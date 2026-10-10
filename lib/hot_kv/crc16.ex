# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.CRC16 do
  @moduledoc """
  CRC16/XMODEM (polynomial `0x1021`, initial value `0`, no reflection) and
  the cluster key slot derived from it, matching `CLUSTER KEYSLOT` and the
  `{hash tag}` rules used by HotKV cluster mode.
  """

  import Bitwise

  @poly 0x1021
  @slots 16384

  @doc """
  Raw CRC16/XMODEM checksum of `data`.

      iex> HotKV.CRC16.crc16("123456789")
      0x31C3
  """
  @spec crc16(binary) :: 0..0xFFFF
  def crc16(data) when is_binary(data) do
    for <<byte <- data>>, reduce: 0 do
      crc -> step(bxor(crc, byte <<< 8))
    end
  end

  defp step(crc), do: step(crc, 8)

  defp step(crc, 0), do: crc &&& 0xFFFF

  defp step(crc, n) do
    next = if (crc &&& 0x8000) != 0, do: bxor(crc <<< 1, @poly), else: crc <<< 1
    step(next, n - 1)
  end

  @doc """
  The cluster hash slot (`0..16383`) for `key`, honoring `{hash tag}`
  substrings exactly like `CLUSTER KEYSLOT`: when `key` contains `{` followed
  somewhere after it by `}` with at least one byte between them, only the
  bytes between the braces are hashed; otherwise the whole key is hashed.

      iex> HotKV.CRC16.key_slot("foo")
      12182
      iex> HotKV.CRC16.key_slot("{user1000}.following")
      3443
  """
  @spec key_slot(binary) :: 0..16383
  def key_slot(key) when is_binary(key) do
    crc16(hash_tag(key)) |> rem(@slots)
  end

  # Mirrors the standard cluster key slot rule: find the first '{', then the first
  # '}' after it. Only when that closing brace exists and is not adjacent to
  # the opening one (a non-empty tag) do we hash the substring between them;
  # otherwise (no '{', no matching '}', or an empty "{}") the whole key is
  # hashed, without searching for a second '{...}' pair.
  defp hash_tag(key) do
    case :binary.match(key, "{") do
      :nomatch ->
        key

      {open, _len} ->
        after_open = binary_part(key, open + 1, byte_size(key) - open - 1)

        case :binary.match(after_open, "}") do
          {close, _len} when close > 0 -> binary_part(after_open, 0, close)
          _ -> key
        end
    end
  end
end

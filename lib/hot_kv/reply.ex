# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Reply do
  @moduledoc """
  Helpers command wrapper modules use to normalize a reply into one shape
  regardless of whether the server sent it as RESP2 or as a native RESP3
  type (`HotKV.RESP` already decodes both; this module bridges the
  remaining differences, such as a flat array versus a native map).
  """

  @doc "Wraps a transform around the `:ok` half of a `command/2` result, leaving errors untouched."
  @spec map({:ok, term} | {:error, term}, (term -> term)) :: {:ok, term} | {:error, term}
  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = error, _fun), do: error

  @doc """
  Normalizes a flat key/value reply to a map: a native RESP3 map is
  returned as-is; a RESP2 flat list `[k1, v1, k2, v2, ...]` is folded into
  one.
  """
  @spec to_map(map | list) :: map
  def to_map(map) when is_map(map), do: map

  def to_map(list) when is_list(list) do
    list |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)
  end

  @doc """
  Normalizes a flat reply to an ordered list of `{key, value}` pairs:
  accepts a native RESP3 map, a RESP3 array-of-pairs (nested 2-element
  arrays, as ZRANGE WITHSCORES uses), or a RESP2 flat list.
  """
  @spec to_pairs(map | list) :: [{term, term}]
  def to_pairs(map) when is_map(map), do: Map.to_list(map)
  def to_pairs([[_, _] | _] = nested), do: Enum.map(nested, fn [k, v] -> {k, v} end)
  def to_pairs([]), do: []

  def to_pairs(list) when is_list(list),
    do: list |> Enum.chunk_every(2) |> Enum.map(fn [k, v] -> {k, v} end)

  @doc "Normalizes a RESP2 list or RESP3 `MapSet` reply to a `MapSet`."
  @spec to_set(list | MapSet.t()) :: MapSet.t()
  def to_set(%MapSet{} = set), do: set
  def to_set(list) when is_list(list), do: MapSet.new(list)

  @doc """
  Normalizes a numeric/score reply: a RESP3 double is already a float (or
  one of `:inf` / `:"-inf"` / `:nan`, the BEAM's native float cannot
  represent those); a RESP2 bulk string is parsed the same way HotKV
  itself formats scores (including `"inf"`, `"-inf"`, `"nan"`).
  """
  @spec to_double(binary | float | :inf | :"-inf" | :nan) :: float | :inf | :"-inf" | :nan
  def to_double(f) when is_float(f), do: f
  def to_double(a) when a in [:inf, :"-inf", :nan], do: a
  def to_double("inf"), do: :inf
  def to_double("+inf"), do: :inf
  def to_double("-inf"), do: :"-inf"
  def to_double("nan"), do: :nan
  def to_double("-nan"), do: :nan

  def to_double(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {f, _rest} -> f
      :error -> bin
    end
  end

  @doc "Normalizes an integer `0`/`1` or a RESP3 boolean reply to a boolean."
  @spec to_bool(0 | 1 | boolean) :: boolean
  def to_bool(b) when is_boolean(b), do: b
  def to_bool(0), do: false
  def to_bool(1), do: true

  @doc "True for the `\"OK\"` simple-string reply most write commands use."
  @spec ok?(term) :: boolean
  def ok?("OK"), do: true
  def ok?(_), do: false
end

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.SortedSets do
  @moduledoc "Sorted set commands."

  alias HotKV.{Args, Error, Reply, Scan}

  @type conn :: HotKV.conn()
  @type key :: String.t()
  @type score :: float | integer | String.t()
  @type member :: binary

  @doc """
  `ZADD key [NX|XX] [GT|LT] [CH] [INCR] score member [score member ...]` ->
  the number of members added (or changed, with `opts[:ch]`); with
  `opts[:incr]`, the member's score after incrementing (or `nil` if a
  condition was not met). `scores_and_members` is `[{score, member}, ...]`.
  """
  @spec zadd(conn, key, [{score, member}], keyword) ::
          {:ok, integer | float | :inf | :"-inf" | :nan | nil} | {:error, Error.t()}
  def zadd(conn, key, scores_and_members, opts \\ []) do
    extra =
      []
      |> Args.flag(opts, :nx, "NX")
      |> Args.flag(opts, :xx, "XX")
      |> Args.flag(opts, :gt, "GT")
      |> Args.flag(opts, :lt, "LT")
      |> Args.flag(opts, :ch, "CH")
      |> Args.flag(opts, :incr, "INCR")

    body = Enum.flat_map(scores_and_members, fn {score, member} -> [score_arg(score), member] end)
    result = HotKV.command(conn, ["ZADD", key | extra] ++ body)
    if Keyword.get(opts, :incr), do: Reply.map(result, &nilable_double/1), else: result
  end

  @doc "`ZREM key member [member ...]` -> the number of members removed."
  @spec zrem(conn, key, member | [member]) :: {:ok, integer} | {:error, Error.t()}
  def zrem(conn, key, members), do: HotKV.command(conn, ["ZREM", key | Args.wrap(members)])

  @doc "`ZSCORE key member` -> the member's score, `nil` if not a member."
  @spec zscore(conn, key, member) ::
          {:ok, float | :inf | :"-inf" | :nan | nil} | {:error, Error.t()}
  def zscore(conn, key, member),
    do: conn |> HotKV.command(["ZSCORE", key, member]) |> Reply.map(&nilable_double/1)

  @doc "`ZMSCORE key member [member ...]` -> a score per member, in order, `nil` for non-members."
  @spec zmscore(conn, key, [member]) ::
          {:ok, [float | :inf | :"-inf" | :nan | nil]} | {:error, Error.t()}
  def zmscore(conn, key, members) do
    conn
    |> HotKV.command(["ZMSCORE", key | members])
    |> Reply.map(&Enum.map(&1, fn s -> nilable_double(s) end))
  end

  @doc "`ZINCRBY key increment member` -> the member's score after incrementing."
  @spec zincrby(conn, key, score, member) ::
          {:ok, float | :inf | :"-inf" | :nan} | {:error, Error.t()}
  def zincrby(conn, key, increment, member) do
    conn
    |> HotKV.command(["ZINCRBY", key, score_arg(increment), member])
    |> Reply.map(&Reply.to_double/1)
  end

  @doc "`ZCARD key` -> the number of members, `0` if `key` does not exist."
  @spec zcard(conn, key) :: {:ok, integer} | {:error, Error.t()}
  def zcard(conn, key), do: HotKV.command(conn, ["ZCARD", key])

  @doc "`ZCOUNT key min max` -> the number of members with a score in `[min, max]` (standard range syntax, e.g. `\"(1\"`, `\"+inf\"`)."
  @spec zcount(conn, key, score, score) :: {:ok, integer} | {:error, Error.t()}
  def zcount(conn, key, min, max),
    do: HotKV.command(conn, ["ZCOUNT", key, score_arg(min), score_arg(max)])

  @doc "`ZLEXCOUNT key min max` -> the number of members in the lexicographical range `[min, max]`."
  @spec zlexcount(conn, key, String.t(), String.t()) :: {:ok, integer} | {:error, Error.t()}
  def zlexcount(conn, key, min, max), do: HotKV.command(conn, ["ZLEXCOUNT", key, min, max])

  @doc """
  `ZRANGE key start stop [BYSCORE|BYLEX] [REV] [LIMIT off cnt] [WITHSCORES]`
  -> members, or `[{member, score}, ...]` with `opts[:withscores]`.
  """
  @spec zrange(conn, key, term, term, keyword) ::
          {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zrange(conn, key, start_, stop_, opts \\ []) do
    extra =
      []
      |> Args.flag(opts, :byscore, "BYSCORE")
      |> Args.flag(opts, :bylex, "BYLEX")
      |> Args.flag(opts, :rev, "REV")
      |> add_limit(opts)
      |> Args.flag(opts, :withscores, "WITHSCORES")

    conn |> HotKV.command(["ZRANGE", key, start_, stop_ | extra]) |> maybe_pairs(opts)
  end

  @doc "`ZRANGEBYSCORE key min max [LIMIT off cnt] [WITHSCORES]` -> members, or `[{member, score}, ...]`."
  @spec zrangebyscore(conn, key, score, score, keyword) ::
          {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zrangebyscore(conn, key, min, max, opts \\ []) do
    extra = [] |> add_limit(opts) |> Args.flag(opts, :withscores, "WITHSCORES")

    conn
    |> HotKV.command(["ZRANGEBYSCORE", key, score_arg(min), score_arg(max) | extra])
    |> maybe_pairs(opts)
  end

  @doc "`ZREVRANGEBYSCORE key max min [LIMIT off cnt] [WITHSCORES]` -> members, or `[{member, score}, ...]`."
  @spec zrevrangebyscore(conn, key, score, score, keyword) ::
          {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zrevrangebyscore(conn, key, max, min, opts \\ []) do
    extra = [] |> add_limit(opts) |> Args.flag(opts, :withscores, "WITHSCORES")

    conn
    |> HotKV.command(["ZREVRANGEBYSCORE", key, score_arg(max), score_arg(min) | extra])
    |> maybe_pairs(opts)
  end

  @doc "`ZRANGEBYLEX key min max [LIMIT off cnt]` -> members in lexicographical range."
  @spec zrangebylex(conn, key, String.t(), String.t(), keyword) ::
          {:ok, [member]} | {:error, Error.t()}
  def zrangebylex(conn, key, min, max, opts \\ []) do
    HotKV.command(conn, ["ZRANGEBYLEX", key, min, max | add_limit([], opts)])
  end

  @doc "`ZREVRANGEBYLEX key max min [LIMIT off cnt]` -> members in reverse lexicographical range."
  @spec zrevrangebylex(conn, key, String.t(), String.t(), keyword) ::
          {:ok, [member]} | {:error, Error.t()}
  def zrevrangebylex(conn, key, max, min, opts \\ []) do
    HotKV.command(conn, ["ZREVRANGEBYLEX", key, max, min | add_limit([], opts)])
  end

  @doc "`ZREVRANGE key start stop [WITHSCORES]` -> members, highest score first, or `[{member, score}, ...]`."
  @spec zrevrange(conn, key, integer, integer, keyword) ::
          {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zrevrange(conn, key, start_index, stop_index, opts \\ []) do
    extra = Args.flag([], opts, :withscores, "WITHSCORES")

    conn
    |> HotKV.command(["ZREVRANGE", key, start_index, stop_index | extra])
    |> maybe_pairs(opts)
  end

  @doc """
  `ZRANGESTORE destination source start stop [BYSCORE|BYLEX] [REV] [LIMIT off cnt]`
  -> the number of members stored.
  """
  @spec zrangestore(conn, key, key, term, term, keyword) :: {:ok, integer} | {:error, Error.t()}
  def zrangestore(conn, destination, source, start_, stop_, opts \\ []) do
    extra =
      []
      |> Args.flag(opts, :byscore, "BYSCORE")
      |> Args.flag(opts, :bylex, "BYLEX")
      |> Args.flag(opts, :rev, "REV")
      |> add_limit(opts)

    HotKV.command(conn, ["ZRANGESTORE", destination, source, start_, stop_ | extra])
  end

  @doc "`ZRANK key member [WITHSCORE]` -> the 0-based rank (lowest score first), `nil` if not a member; `{rank, score}` with `opts[:withscore]`."
  @spec zrank(conn, key, member, keyword) ::
          {:ok, integer | {integer, float} | nil} | {:error, Error.t()}
  def zrank(conn, key, member, opts \\ []), do: rank(conn, "ZRANK", key, member, opts)

  @doc "`ZREVRANK key member [WITHSCORE]` -> the 0-based rank (highest score first), `nil` if not a member."
  @spec zrevrank(conn, key, member, keyword) ::
          {:ok, integer | {integer, float} | nil} | {:error, Error.t()}
  def zrevrank(conn, key, member, opts \\ []), do: rank(conn, "ZREVRANK", key, member, opts)

  defp rank(conn, cmd, key, member, opts) do
    if Keyword.get(opts, :withscore) do
      conn
      |> HotKV.command([cmd, key, member, "WITHSCORE"])
      |> Reply.map(fn
        nil -> nil
        [rank_value, score] -> {rank_value, Reply.to_double(score)}
      end)
    else
      HotKV.command(conn, [cmd, key, member])
    end
  end

  @doc "`ZREMRANGEBYRANK key start stop` -> the number of members removed."
  @spec zremrangebyrank(conn, key, integer, integer) :: {:ok, integer} | {:error, Error.t()}
  def zremrangebyrank(conn, key, start_index, stop_index),
    do: HotKV.command(conn, ["ZREMRANGEBYRANK", key, start_index, stop_index])

  @doc "`ZREMRANGEBYSCORE key min max` -> the number of members removed."
  @spec zremrangebyscore(conn, key, score, score) :: {:ok, integer} | {:error, Error.t()}
  def zremrangebyscore(conn, key, min, max),
    do: HotKV.command(conn, ["ZREMRANGEBYSCORE", key, score_arg(min), score_arg(max)])

  @doc "`ZREMRANGEBYLEX key min max` -> the number of members removed."
  @spec zremrangebylex(conn, key, String.t(), String.t()) :: {:ok, integer} | {:error, Error.t()}
  def zremrangebylex(conn, key, min, max),
    do: HotKV.command(conn, ["ZREMRANGEBYLEX", key, min, max])

  @doc """
  `ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX]`
  -> the size of the stored result.
  """
  @spec zunionstore(conn, key, [key], keyword) :: {:ok, integer} | {:error, Error.t()}
  def zunionstore(conn, destination, keys, opts \\ []),
    do: store_op(conn, "ZUNIONSTORE", destination, keys, opts)

  @doc "`ZINTERSTORE destination numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE SUM|MIN|MAX]` -> the size of the stored result."
  @spec zinterstore(conn, key, [key], keyword) :: {:ok, integer} | {:error, Error.t()}
  def zinterstore(conn, destination, keys, opts \\ []),
    do: store_op(conn, "ZINTERSTORE", destination, keys, opts)

  @doc "`ZDIFFSTORE destination numkeys key [key ...]` -> the size of the stored result."
  @spec zdiffstore(conn, key, [key]) :: {:ok, integer} | {:error, Error.t()}
  def zdiffstore(conn, destination, keys),
    do: HotKV.command(conn, ["ZDIFFSTORE", destination, length(keys) | keys])

  defp store_op(conn, cmd, destination, keys, opts) do
    extra = [] |> Args.list(opts, :weights, "WEIGHTS") |> add_aggregate(opts)
    HotKV.command(conn, [cmd, destination, length(keys) | keys] ++ extra)
  end

  @doc "`ZUNION numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE ...] [WITHSCORES]` -> members, or `[{member, score}, ...]`."
  @spec zunion(conn, [key], keyword) :: {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zunion(conn, keys, opts \\ []), do: setop(conn, "ZUNION", keys, opts, true)

  @doc "`ZINTER numkeys key [key ...] [WEIGHTS w ...] [AGGREGATE ...] [WITHSCORES]` -> members, or `[{member, score}, ...]`."
  @spec zinter(conn, [key], keyword) :: {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zinter(conn, keys, opts \\ []), do: setop(conn, "ZINTER", keys, opts, true)

  @doc "`ZDIFF numkeys key [key ...] [WITHSCORES]` -> members, or `[{member, score}, ...]`."
  @spec zdiff(conn, [key], keyword) :: {:ok, [member] | [{member, float}]} | {:error, Error.t()}
  def zdiff(conn, keys, opts \\ []), do: setop(conn, "ZDIFF", keys, opts, false)

  defp setop(conn, cmd, keys, opts, weighted?) do
    extra =
      if weighted?,
        do: [] |> Args.list(opts, :weights, "WEIGHTS") |> add_aggregate(opts),
        else: []

    extra = Args.flag(extra, opts, :withscores, "WITHSCORES")
    conn |> HotKV.command([cmd, length(keys) | keys] ++ extra) |> maybe_pairs(opts)
  end

  @doc "`ZINTERCARD numkeys key [key ...] [LIMIT limit]` -> the size of the intersection, without storing it."
  @spec zintercard(conn, [key], keyword) :: {:ok, integer} | {:error, Error.t()}
  def zintercard(conn, keys, opts \\ []) do
    extra = Args.value([], opts, :limit, "LIMIT")
    HotKV.command(conn, ["ZINTERCARD", length(keys) | keys] ++ extra)
  end

  defp add_aggregate(acc, opts) do
    case Keyword.get(opts, :aggregate) do
      nil ->
        acc

      agg when agg in [:sum, :min, :max] ->
        acc ++ ["AGGREGATE", agg |> Atom.to_string() |> String.upcase()]
    end
  end

  @doc """
  `ZPOPMIN key [count]` -> `[{member, score}, ...]` (lowest scores first),
  empty if `key` does not exist.
  """
  @spec zpopmin(conn, key, non_neg_integer | nil) ::
          {:ok, [{member, float}]} | {:error, Error.t()}
  def zpopmin(conn, key, count \\ nil), do: pop(conn, "ZPOPMIN", key, count)

  @doc "`ZPOPMAX key [count]` -> `[{member, score}, ...]` (highest scores first)."
  @spec zpopmax(conn, key, non_neg_integer | nil) ::
          {:ok, [{member, float}]} | {:error, Error.t()}
  def zpopmax(conn, key, count \\ nil), do: pop(conn, "ZPOPMAX", key, count)

  defp pop(conn, cmd, key, nil), do: conn |> HotKV.command([cmd, key]) |> as_pairs()
  defp pop(conn, cmd, key, count), do: conn |> HotKV.command([cmd, key, count]) |> as_pairs()

  @doc """
  `ZRANDMEMBER key [count [WITHSCORES]]` -> a random member (or list, with
  `count`; `[{member, score}, ...]` with `opts[:withscores]`).
  """
  @spec zrandmember(conn, key, integer | nil, keyword) :: {:ok, term} | {:error, Error.t()}
  def zrandmember(conn, key, count \\ nil, opts \\ [])
  def zrandmember(conn, key, nil, _opts), do: HotKV.command(conn, ["ZRANDMEMBER", key])

  def zrandmember(conn, key, count, opts) do
    if Keyword.get(opts, :withscores) do
      conn |> HotKV.command(["ZRANDMEMBER", key, count, "WITHSCORES"]) |> as_pairs()
    else
      HotKV.command(conn, ["ZRANDMEMBER", key, count])
    end
  end

  @doc "A lazy `Stream` over `{member, score}` of `key`, via `ZSCAN`. `opts`: `:match`, `:count`."
  @spec zscan(conn, key, keyword) :: Enumerable.t()
  def zscan(conn, key, opts \\ []) do
    conn
    |> Scan.stream(["ZSCAN", key], opts)
    |> Stream.chunk_every(2)
    |> Stream.map(fn [member, score] -> {member, Reply.to_double(score)} end)
  end

  # -- shared helpers ---------------------------------------------------

  defp maybe_pairs(result, opts) do
    if Keyword.get(opts, :withscores), do: as_pairs(result), else: result
  end

  defp as_pairs(result) do
    Reply.map(result, fn reply ->
      reply
      |> Reply.to_pairs()
      |> Enum.map(fn {member, score} -> {member, Reply.to_double(score)} end)
    end)
  end

  defp add_limit(acc, opts) do
    case Keyword.get(opts, :limit) do
      nil -> acc
      {offset, count} -> acc ++ ["LIMIT", offset, count]
    end
  end

  defp nilable_double(nil), do: nil
  defp nilable_double(value), do: Reply.to_double(value)

  defp score_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp score_arg(value), do: value
end

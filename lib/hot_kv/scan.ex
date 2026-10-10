# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Scan do
  @moduledoc """
  The shared cursor-iteration engine behind `SCAN`, `HSCAN`, `SSCAN` and
  `ZSCAN`, exposed as a lazy `Stream`. Most callers use the friendlier
  entry points instead: `HotKV.Keys.scan/2`, `HotKV.Hashes.hscan/3`,
  `HotKV.Sets.sscan/3`, `HotKV.SortedSets.zscan/3`.
  """

  @doc """
  Builds a lazy `Stream` over every element `command_args ++ [cursor,
  ...options]` (with `cursor` starting at `"0"`) yields across as many
  round trips as it takes for the server to report cursor `"0"` again.

  `opts`:

    * `:match` - a glob pattern, passed as `MATCH`.
    * `:count` - a hint for how many elements to examine per call, passed
      as `COUNT`.
    * `:type` - (plain `SCAN` only) restricts to one value type, passed as
      `TYPE`.

  If a call fails, the error is raised (as a `HotKV.Error`) when the stream
  reaches that point.
  """
  @spec stream(HotKV.conn(), [term], keyword) :: Enumerable.t()
  def stream(conn, command_args, opts \\ []) do
    extra = scan_opts(opts)

    Stream.resource(
      fn -> "0" end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          case HotKV.command(conn, command_args ++ [cursor | extra]) do
            {:ok, [next_cursor, items]} -> {items, next_acc(next_cursor)}
            {:error, error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp next_acc("0"), do: :done
  defp next_acc(cursor), do: cursor

  defp scan_opts(opts) do
    []
    |> add_opt("MATCH", Keyword.get(opts, :match))
    |> add_opt("COUNT", Keyword.get(opts, :count))
    |> add_opt("TYPE", Keyword.get(opts, :type))
  end

  defp add_opt(acc, _keyword, nil), do: acc
  defp add_opt(acc, keyword, value), do: acc ++ [keyword, to_string(value)]
end

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Vsim do
  @moduledoc """
  `VSIM.*`: vector similarity indexes. Core, no license required, except
  `save/2`, `load/2`, `list_snapshots/1` and `drop_snapshot/2`
  (these need a server license that includes the VSIM persistence feature).
  """

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type vector :: [float | integer]

  @doc """
  `VSIM.CREATEINDEX name dims [METRIC cosine|l2|ip] [M n] [EF_CONSTRUCTION n] [EF_SEARCH n]`
  -> `\"OK\"`. `dims` in `1..65536`. `opts`: `:metric` (`:cosine` (default),
  `:l2`, `:ip`), `:m`, `:ef_construction`, `:ef_search`.
  """
  @spec createindex(conn, String.t(), pos_integer, keyword) ::
          {:ok, String.t()} | {:error, Error.t()}
  def createindex(conn, name, dims, opts \\ []) do
    extra =
      []
      |> add_metric(opts)
      |> Args.value(opts, :m, "M")
      |> Args.value(opts, :ef_construction, "EF_CONSTRUCTION")
      |> Args.value(opts, :ef_search, "EF_SEARCH")

    HotKV.command(conn, ["VSIM.CREATEINDEX", name, dims | extra])
  end

  defp add_metric(acc, opts) do
    case Keyword.get(opts, :metric) do
      nil -> acc
      metric when metric in [:cosine, :l2, :ip] -> acc ++ ["METRIC", Atom.to_string(metric)]
    end
  end

  @doc "`VSIM.DROPINDEX name` -> `\"OK\"`."
  @spec dropindex(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def dropindex(conn, name), do: HotKV.command(conn, ["VSIM.DROPINDEX", name])

  @doc "`VSIM.SET index key val1 val2 ... valN` -> `true` if newly inserted, `false` if it replaced an existing vector."
  @spec set(conn, String.t(), String.t(), vector) :: {:ok, boolean} | {:error, Error.t()}
  def set(conn, index, key, vector) do
    conn
    |> HotKV.command(["VSIM.SET", index, key | vector_args(vector)])
    |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`VSIM.GET index key` -> the stored vector, `nil` if `key` is not in the index."
  @spec get(conn, String.t(), String.t()) :: {:ok, [float] | nil} | {:error, Error.t()}
  def get(conn, index, key) do
    conn
    |> HotKV.command(["VSIM.GET", index, key])
    |> Reply.map(fn
      nil -> nil
      values -> Enum.map(values, &Reply.to_double/1)
    end)
  end

  @doc "`VSIM.DEL index key` -> `true` if removed."
  @spec del(conn, String.t(), String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def del(conn, index, key),
    do: conn |> HotKV.command(["VSIM.DEL", index, key]) |> Reply.map(&Reply.to_bool/1)

  @doc """
  `VSIM.SEARCH index k val1 ... valN [FILTER tag [tag ...]] [EF ef]` ->
  `[{key, distance}, ...]`, nearest first, up to `k` results. `opts`:
  `:filter` (list of tags, ALL required), `:ef`.
  """
  @spec search(conn, String.t(), pos_integer, vector, keyword) ::
          {:ok, [{String.t(), float}]} | {:error, Error.t()}
  def search(conn, index, k, vector, opts \\ []) do
    extra = [] |> Args.list(opts, :filter, "FILTER") |> Args.value(opts, :ef, "EF")

    conn
    |> HotKV.command(["VSIM.SEARCH", index, k | vector_args(vector)] ++ extra)
    |> Reply.map(fn flat ->
      flat |> Enum.chunk_every(2) |> Enum.map(fn [key, dist] -> {key, Reply.to_double(dist)} end)
    end)
  end

  @doc "`VSIM.INFO` -> every index name."
  @spec info(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def info(conn), do: HotKV.command(conn, ["VSIM.INFO"])

  @doc """
  `VSIM.INFO index` -> `%{"name" => ..., "dimensions" => ..., "metric" =>
  ..., "vectors" => ..., "M" => ..., "ef_construction" => ..., "ef_search"
  => ...}`.
  """
  @spec info(conn, String.t()) :: {:ok, map} | {:error, Error.t()}
  def info(conn, index),
    do: conn |> HotKV.command(["VSIM.INFO", index]) |> Reply.map(&Reply.to_map/1)

  @doc """
  `VSIM.SAVE snapshot_name blob` -> the number of bytes written to the
  snapshot file (a 12 byte header plus the blob). Requires `vsim-persist`.
  A snapshot name is at most 128 bytes and may not contain `/`, a backslash, `.`,
  `:` or control characters.
  """
  @spec save(conn, String.t(), binary) :: {:ok, integer} | {:error, Error.t()}
  def save(conn, snapshot_name, blob), do: HotKV.command(conn, ["VSIM.SAVE", snapshot_name, blob])

  @doc "`VSIM.LOAD snapshot_name` -> the saved blob, `nil` if not found. Requires `vsim-persist`."
  @spec load(conn, String.t()) :: {:ok, binary | nil} | {:error, Error.t()}
  def load(conn, snapshot_name), do: HotKV.command(conn, ["VSIM.LOAD", snapshot_name])

  @doc "`VSIM.LIST` -> every snapshot name. Requires `vsim-persist`."
  @spec list_snapshots(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list_snapshots(conn), do: HotKV.command(conn, ["VSIM.LIST"])

  @doc "`VSIM.DROP snapshot_name` -> `true` if removed. Requires `vsim-persist`."
  @spec drop_snapshot(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop_snapshot(conn, snapshot_name),
    do: conn |> HotKV.command(["VSIM.DROP", snapshot_name]) |> Reply.map(&Reply.to_bool/1)

  defp vector_args(vector), do: Enum.map(vector, &vector_arg/1)
  defp vector_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp vector_arg(value), do: value
end

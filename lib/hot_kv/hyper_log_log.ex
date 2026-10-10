# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.HyperLogLog do
  @moduledoc "HyperLogLog commands (approximate cardinality counting)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`PFADD key [element ...]` -> `true` if the estimated cardinality register was altered."
  @spec pfadd(conn, key, binary | [binary]) :: {:ok, boolean} | {:error, Error.t()}
  def pfadd(conn, key, elements \\ []) do
    conn |> HotKV.command(["PFADD", key | List.wrap(elements)]) |> Reply.map(&Reply.to_bool/1)
  end

  @doc "`PFCOUNT key [key ...]` -> the approximated cardinality of the (implicit) union."
  @spec pfcount(conn, key | [key]) :: {:ok, integer} | {:error, Error.t()}
  def pfcount(conn, keys), do: HotKV.command(conn, ["PFCOUNT" | List.wrap(keys)])

  @doc "`PFMERGE destination [sourcekey ...]` -> `\"OK\"`."
  @spec pfmerge(conn, key, key | [key]) :: {:ok, String.t()} | {:error, Error.t()}
  def pfmerge(conn, destination, source_keys \\ []),
    do: HotKV.command(conn, ["PFMERGE", destination | List.wrap(source_keys)])
end

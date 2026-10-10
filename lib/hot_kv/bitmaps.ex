# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Bitmaps do
  @moduledoc "Bitmap commands."

  alias HotKV.Error

  @type conn :: HotKV.conn()
  @type key :: String.t()

  @doc "`SETBIT key offset value` -> the bit's previous value (`0` or `1`)."
  @spec setbit(conn, key, non_neg_integer, 0 | 1) :: {:ok, integer} | {:error, Error.t()}
  def setbit(conn, key, offset, value), do: HotKV.command(conn, ["SETBIT", key, offset, value])

  @doc "`GETBIT key offset` -> the bit's value (`0` or `1`)."
  @spec getbit(conn, key, non_neg_integer) :: {:ok, integer} | {:error, Error.t()}
  def getbit(conn, key, offset), do: HotKV.command(conn, ["GETBIT", key, offset])

  @doc "`BITCOUNT key [start end [BYTE|BIT]]` -> the number of set bits."
  @spec bitcount(conn, key, integer | nil, integer | nil, :byte | :bit) ::
          {:ok, integer} | {:error, Error.t()}
  def bitcount(conn, key, start_index \\ nil, end_index \\ nil, unit \\ :byte)
  def bitcount(conn, key, nil, nil, _unit), do: HotKV.command(conn, ["BITCOUNT", key])

  def bitcount(conn, key, start_index, end_index, unit) do
    HotKV.command(conn, ["BITCOUNT", key, start_index, end_index, unit_arg(unit)])
  end

  @doc "`BITPOS key bit [start [end [BYTE|BIT]]]` -> the index of the first matching bit, `-1` if not found."
  @spec bitpos(conn, key, 0 | 1, integer | nil, integer | nil, :byte | :bit) ::
          {:ok, integer} | {:error, Error.t()}
  def bitpos(conn, key, bit, start_index \\ nil, end_index \\ nil, unit \\ :byte) do
    extra =
      case {start_index, end_index} do
        {nil, nil} -> []
        {start_index, nil} -> [start_index]
        {start_index, end_index} -> [start_index, end_index, unit_arg(unit)]
      end

    HotKV.command(conn, ["BITPOS", key, bit | extra])
  end

  defp unit_arg(:byte), do: "BYTE"
  defp unit_arg(:bit), do: "BIT"

  @doc "`BITOP AND|OR|XOR|NOT destination key [key ...]` -> the size of the stored result."
  @spec bitop(conn, :and | :or | :xor | :not, key, key | [key]) ::
          {:ok, integer} | {:error, Error.t()}
  def bitop(conn, operation, destination, keys) do
    op = operation |> Atom.to_string() |> String.upcase()
    HotKV.command(conn, ["BITOP", op, destination | List.wrap(keys)])
  end

  @doc "`BITFIELD key subcommand [arg ...]` -> one reply per subcommand. `operations` is a flat token list, e.g. `[\"GET\", \"u8\", \"0\"]`."
  @spec bitfield(conn, key, [term]) :: {:ok, [integer | nil]} | {:error, Error.t()}
  def bitfield(conn, key, operations), do: HotKV.command(conn, ["BITFIELD", key | operations])
end

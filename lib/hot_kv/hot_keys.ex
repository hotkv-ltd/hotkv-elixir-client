# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.HotKeys do
  @moduledoc "`HOTKEYS`: the most frequently accessed keys. Core (admin), no license required."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`HOTKEYS TOP [count]` -> `[{key, count}, ...]`, most frequently accessed first. `count` defaults to 10."
  @spec top(conn, pos_integer | nil) :: {:ok, [{String.t(), integer}]} | {:error, Error.t()}
  def top(conn, count \\ nil)
  def top(conn, nil), do: conn |> HotKV.command(["HOTKEYS", "TOP"]) |> Reply.map(&pairs/1)

  def top(conn, count),
    do: conn |> HotKV.command(["HOTKEYS", "TOP", count]) |> Reply.map(&pairs/1)

  defp pairs(list), do: Enum.map(list, fn [key, count] -> {key, count} end)

  @doc "`HOTKEYS RESET` -> `\"OK\"`."
  @spec reset(conn) :: {:ok, String.t()} | {:error, Error.t()}
  def reset(conn), do: HotKV.command(conn, ["HOTKEYS", "RESET"])
end

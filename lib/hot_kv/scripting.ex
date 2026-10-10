# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Scripting do
  @moduledoc "Lua scripting commands (`EVAL`/`EVALSHA`/`SCRIPT`)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`EVAL script numkeys key [key ...] arg [arg ...]` -> the script's return value."
  @spec eval(conn, String.t(), [String.t()], [term]) :: {:ok, term} | {:error, Error.t()}
  def eval(conn, script, keys \\ [], args \\ []) do
    HotKV.command(conn, ["EVAL", script, length(keys)] ++ keys ++ args)
  end

  @doc "`EVALSHA sha1 numkeys key [key ...] arg [arg ...]` -> the script's return value, or a `NOSCRIPT` server error if it is not cached."
  @spec evalsha(conn, String.t(), [String.t()], [term]) :: {:ok, term} | {:error, Error.t()}
  def evalsha(conn, sha, keys \\ [], args \\ []) do
    HotKV.command(conn, ["EVALSHA", sha, length(keys)] ++ keys ++ args)
  end

  @doc """
  Like `evalsha/4`, but transparently sends `EVAL script ...` instead when
  the server has not cached `script` (a `NOSCRIPT` reply), so callers never
  need to `SCRIPT LOAD` by hand.
  """
  @spec eval_auto(conn, String.t(), [String.t()], [term]) :: {:ok, term} | {:error, Error.t()}
  def eval_auto(conn, script, keys \\ [], args \\ []) do
    case evalsha(conn, sha1(script), keys, args) do
      {:error, %Error{kind: :server, prefix: "NOSCRIPT"}} -> eval(conn, script, keys, args)
      other -> other
    end
  end

  @doc "The SHA-1 hex digest `EVALSHA`/`SCRIPT EXISTS` identify a script by."
  @spec sha1(String.t()) :: String.t()
  def sha1(script), do: :crypto.hash(:sha, script) |> Base.encode16(case: :lower)

  @doc "`SCRIPT LOAD script` -> the script's SHA-1 hex digest, for later `EVALSHA` calls."
  @spec script_load(conn, String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def script_load(conn, script), do: HotKV.command(conn, ["SCRIPT", "LOAD", script])

  @doc "`SCRIPT EXISTS sha1 [sha1 ...]` -> whether each script is cached, in order."
  @spec script_exists(conn, String.t() | [String.t()]) :: {:ok, [boolean]} | {:error, Error.t()}
  def script_exists(conn, shas) do
    conn
    |> HotKV.command(["SCRIPT", "EXISTS" | List.wrap(shas)])
    |> Reply.map(&Enum.map(&1, fn v -> Reply.to_bool(v) end))
  end

  @doc "`SCRIPT FLUSH` -> `\"OK\"`. Clears the script cache."
  @spec script_flush(conn) :: {:ok, String.t()} | {:error, Error.t()}
  def script_flush(conn), do: HotKV.command(conn, ["SCRIPT", "FLUSH"])
end

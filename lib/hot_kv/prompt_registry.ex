# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.PromptRegistry do
  @moduledoc "`PROMPT.*`: the versioned prompt/template registry (needs a server license that includes the prompt-registry feature)."

  alias HotKV.{Error, Reply}

  @type conn :: HotKV.conn()

  @doc "`PROMPT.PUT name content [META json]` -> the new version number (starts at 1), or a server error if the template limit is reached."
  @spec put(conn, String.t(), String.t(), String.t() | nil) ::
          {:ok, integer} | {:error, Error.t()}
  def put(conn, name, content, meta \\ nil) do
    extra = if meta, do: ["META", meta], else: []
    HotKV.command(conn, ["PROMPT.PUT", name, content | extra])
  end

  @doc "`PROMPT.GET name [version]` -> `%{version:, content:, metadata:, created_unix:}`, `nil` if not found. Omit `version` (or `0`) for the latest."
  @spec get(conn, String.t(), non_neg_integer | nil) :: {:ok, map | nil} | {:error, Error.t()}
  def get(conn, name, version \\ nil)

  def get(conn, name, nil),
    do: conn |> HotKV.command(["PROMPT.GET", name]) |> Reply.map(&as_version/1)

  def get(conn, name, version),
    do: conn |> HotKV.command(["PROMPT.GET", name, version]) |> Reply.map(&as_version/1)

  @doc "`PROMPT.LATEST name` -> `%{version:, content:, metadata:, created_unix:}`, `nil` if not found."
  @spec latest(conn, String.t()) :: {:ok, map | nil} | {:error, Error.t()}
  def latest(conn, name),
    do: conn |> HotKV.command(["PROMPT.LATEST", name]) |> Reply.map(&as_version/1)

  defp as_version(nil), do: nil

  defp as_version([version, content, metadata, created_unix]) do
    %{version: version, content: content, metadata: metadata, created_unix: created_unix}
  end

  @doc "`PROMPT.SETACTIVE name version` -> `\"OK\"`, or a server error if the template or version is not found."
  @spec setactive(conn, String.t(), non_neg_integer) :: {:ok, String.t()} | {:error, Error.t()}
  def setactive(conn, name, version), do: HotKV.command(conn, ["PROMPT.SETACTIVE", name, version])

  @doc "`PROMPT.VERSIONS name` -> every stored version number."
  @spec versions(conn, String.t()) :: {:ok, [integer]} | {:error, Error.t()}
  def versions(conn, name), do: HotKV.command(conn, ["PROMPT.VERSIONS", name])

  @doc "`PROMPT.DROP name` -> `true` if the template existed."
  @spec drop(conn, String.t()) :: {:ok, boolean} | {:error, Error.t()}
  def drop(conn, name),
    do: conn |> HotKV.command(["PROMPT.DROP", name]) |> Reply.map(&Reply.to_bool/1)

  @doc "`PROMPT.LIST` -> every template name."
  @spec list(conn) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(conn), do: HotKV.command(conn, ["PROMPT.LIST"])
end

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Error do
  @moduledoc """
  Typed error returned by HotKV operations.

  Every `{:error, reason}` tuple returned from this library carries a
  `HotKV.Error` struct as `reason`, and it is also a proper `Exception` so
  the bang (`!`) functions can simply `raise/1` it.

  The `:kind` field groups errors the same way across every official HotKV
  SDK:

    * `:connection` - could not establish or maintain the TCP/TLS connection.
    * `:timeout` - a command did not receive a reply within its timeout.
    * `:protocol` - the server sent bytes that do not parse as RESP2/RESP3.
    * `:server` - the server replied with a RESP error, for example
      `WRONGTYPE`, `NOAUTH`, `ERR ...`. `:prefix` holds the error's leading
      token.
    * `:not_licensed` - the server replied with a `NOLICENSE` error because
      the connected license does not include the feature the command needs.
      This is a distinct kind (rather than a generic `:server` error) so
      integration tests, and application code, can detect and skip on it
      with `HotKV.Error.not_licensed?/1`.
    * `:cluster_redirect` - the server replied `MOVED` or `ASK`; `:redirect`
      holds `%{type: :moved | :ask, slot: integer, host: binary, port: integer}`.
      Application code does not usually see this kind directly: `HotKV.Cluster`
      follows redirects itself and only exhausts them (returning this error)
      after `:max_redirects` hops.
  """

  defexception [:kind, :message, :prefix, :redirect]

  @type kind :: :connection | :timeout | :protocol | :server | :not_licensed | :cluster_redirect

  @type redirect :: %{type: :moved | :ask, slot: non_neg_integer, host: binary, port: pos_integer}

  @type t :: %__MODULE__{
          kind: kind,
          message: String.t(),
          prefix: String.t() | nil,
          redirect: redirect | nil
        }

  @impl true
  def message(%__MODULE__{message: message}), do: message

  @doc "Builds a `:connection` error."
  @spec connection(String.t()) :: t
  def connection(message), do: %__MODULE__{kind: :connection, message: message}

  @doc "Builds a `:timeout` error."
  @spec timeout(String.t()) :: t
  def timeout(message \\ "command timed out"), do: %__MODULE__{kind: :timeout, message: message}

  @doc "Builds a `:protocol` error."
  @spec protocol(String.t()) :: t
  def protocol(message), do: %__MODULE__{kind: :protocol, message: message}

  @doc """
  Builds a server-reply error from its RESP error line, e.g.
  `"WRONGTYPE Operation against a key holding the wrong kind of value"` or
  `"NOLICENSE enterprise feature 'prompt-cache' requires a valid license"`.

  The leading whitespace-delimited token becomes `:prefix`. A `NOLICENSE`
  prefix produces `:kind == :not_licensed`; anything else produces
  `:kind == :server`.
  """
  @spec server(String.t()) :: t
  def server(full_message) when is_binary(full_message) do
    prefix =
      case String.split(full_message, " ", parts: 2) do
        [p, _rest] -> p
        [p] -> p
      end

    kind = if prefix == "NOLICENSE", do: :not_licensed, else: :server
    %__MODULE__{kind: kind, message: full_message, prefix: prefix}
  end

  @doc "Builds a `:cluster_redirect` error from a MOVED/ASK error line."
  @spec cluster_redirect(String.t()) :: t
  def cluster_redirect(full_message) when is_binary(full_message) do
    case String.split(full_message, " ") do
      [type, slot, hostport] when type in ["MOVED", "ASK"] ->
        {host, port} = split_host_port(hostport)

        %__MODULE__{
          kind: :cluster_redirect,
          message: full_message,
          prefix: type,
          redirect: %{
            type: if(type == "MOVED", do: :moved, else: :ask),
            slot: String.to_integer(slot),
            host: host,
            port: port
          }
        }

      _ ->
        server(full_message)
    end
  end

  defp split_host_port(hostport) do
    case String.split(hostport, ":") do
      [host] ->
        {host, 0}

      parts ->
        {port_str, host_parts} = List.pop_at(parts, -1)
        host = Enum.join(host_parts, ":")
        port = String.to_integer(port_str)
        {host, port}
    end
  end

  @doc "True if `error` is a `NOLICENSE` reply from the server."
  @spec not_licensed?(any) :: boolean
  def not_licensed?(%__MODULE__{kind: :not_licensed}), do: true
  def not_licensed?(_), do: false

  @doc "True if `error` is a MOVED or ASK cluster redirect."
  @spec cluster_redirect?(any) :: boolean
  def cluster_redirect?(%__MODULE__{kind: :cluster_redirect}), do: true
  def cluster_redirect?(_), do: false

  @doc "True if `error` is a `WRONGTYPE` server reply."
  @spec wrong_type?(any) :: boolean
  def wrong_type?(%__MODULE__{kind: :server, prefix: "WRONGTYPE"}), do: true
  def wrong_type?(_), do: false
end

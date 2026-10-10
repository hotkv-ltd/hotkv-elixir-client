# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TestSupport.FakeServer do
  @moduledoc false
  # A scriptable RESP server on a loopback port, for unit tests that need a
  # real socket but not a real HotKV server (timeouts, cluster redirects,
  # connection loss). `start/1` takes a handler `fn args -> reply end` that
  # is called once per received command (`args` is the list of binaries) and
  # returns either iodata to write back (already RESP encoded, see the
  # `simple/1`, `error/1`, `int/1`, `bulk/1`, `array/1` helpers), `:no_reply`
  # (send nothing, to provoke a client timeout) or `:close` (drop the
  # connection). `HELLO` is answered with an error unless the handler
  # answers it, so clients fall back to RESP2.

  @doc """
  Starts the server; returns `{port, pid}`. The server stops when the test
  process exits. `opts[:tls]` is `[certfile: path, keyfile: path]` to serve
  TLS instead of plain TCP.
  """
  def start(handler, opts \\ []) do
    parent = self()
    tls = Keyword.get(opts, :tls)
    mod = if tls, do: :ssl, else: :gen_tcp
    listen_opts = [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ (tls || [])

    {:ok, listen} = mod.listen(0, listen_opts)
    {:ok, {_, port}} = if tls, do: :ssl.sockname(listen), else: :inet.sockname(listen)

    pid =
      spawn_link(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:fake_server_ready, self()})
        accept_loop(mod, listen, handler)
      end)

    receive do
      {:fake_server_ready, ^pid} -> :ok
    end

    ExUnit.Callbacks.on_exit(fn -> mod.close(listen) end)
    {port, pid}
  end

  def simple(text), do: ["+", text, "\r\n"]
  def error(text), do: ["-", text, "\r\n"]
  def int(n), do: [":", Integer.to_string(n), "\r\n"]
  def bulk(nil), do: "$-1\r\n"
  def bulk(text), do: ["$", Integer.to_string(byte_size(text)), "\r\n", text, "\r\n"]

  def array(items) when is_list(items),
    do: ["*", Integer.to_string(length(items)), "\r\n" | items]

  defp accept_loop(:gen_tcp, listen, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(:gen_tcp, socket, handler, <<>>) end)
        :gen_tcp.controlling_process(socket, pid)
        accept_loop(:gen_tcp, listen, handler)

      {:error, _} ->
        :ok
    end
  end

  defp accept_loop(:ssl, listen, handler) do
    case :ssl.transport_accept(listen) do
      {:ok, socket} ->
        pid =
          spawn(fn ->
            receive do
              :go -> :ok
            end

            case :ssl.handshake(socket, 5_000) do
              {:ok, tls_socket} -> serve(:ssl, tls_socket, handler, <<>>)
              {:error, _} -> :ok
            end
          end)

        :ssl.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(:ssl, listen, handler)

      {:error, _} ->
        :ok
    end
  end

  defp serve(mod, socket, handler, buffer) do
    case parse(buffer) do
      {:ok, args, rest} ->
        case dispatch(handler, args) do
          :no_reply ->
            serve(mod, socket, handler, rest)

          :close ->
            mod.close(socket)

          reply ->
            mod.send(socket, reply)
            serve(mod, socket, handler, rest)
        end

      :incomplete ->
        case mod.recv(socket, 0) do
          {:ok, data} -> serve(mod, socket, handler, buffer <> data)
          {:error, _} -> :ok
        end
    end
  end

  defp dispatch(handler, args) do
    case handler.(args) do
      nil -> default(args)
      reply -> reply
    end
  end

  defp default(["HELLO" | _]), do: error("ERR unknown command 'HELLO'")
  defp default(_args), do: error("ERR unknown command")

  # "*N\r\n$len\r\nbytes\r\n..." -> {:ok, [bytes, ...], rest} | :incomplete
  defp parse("*" <> rest) do
    with {:ok, count, body} <- take_int(rest) do
      bulks(body, count, [])
    end
  end

  defp parse(_), do: :incomplete

  defp bulks(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp bulks("$" <> rest, count, acc) do
    with {:ok, len, body} <- take_int(rest),
         <<bytes::binary-size(len), "\r\n", tail::binary>> <- body do
      bulks(tail, count - 1, [bytes | acc])
    else
      _ -> :incomplete
    end
  end

  defp bulks(_, _, _), do: :incomplete

  defp take_int(binary) do
    case :binary.split(binary, "\r\n") do
      [line, rest] -> {:ok, String.to_integer(line), rest}
      _ -> :incomplete
    end
  end
end

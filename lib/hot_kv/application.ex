# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # HotKV.Connection, HotKV.Pool and HotKV.PubSub processes are started by
    # the application that uses this library (typically under its own
    # supervision tree, via `{HotKV, ...}` or `{HotKV.Pool, ...}` child
    # specs) rather than by this library's own application. This
    # supervisor exists so `hotkv` is a well-behaved OTP application with a
    # supervision tree of its own to extend if a future release needs
    # library-owned, always-on processes.
    children = []

    # pid -> :command_timeout of every running HotKV.Connection.
    _ =
      :ets.new(HotKV.Connection.timeout_table(), [:named_table, :public, read_concurrency: true])

    Supervisor.start_link(children, strategy: :one_for_one, name: HotKV.Supervisor)
  end
end

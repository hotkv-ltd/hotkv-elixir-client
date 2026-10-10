# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Link do
  @moduledoc false
  # Starts a GenServer linked to the caller, but without killing the caller
  # when `init/1` fails.
  #
  # `GenServer.start_link/3` links before `init/1` runs, so an init that
  # returns `{:stop, reason}` (a refused connection, a rejected password)
  # exits the new process with a non-normal reason and that exit signal
  # takes down a caller that is not trapping exits, even though start_link
  # also returns `{:error, reason}`. Starting unlinked and linking only once
  # the process is up gives the documented behavior: `{:error, reason}` and
  # a caller that lives on. A supervisor still gets a linked child.

  @spec start_link(module, term, GenServer.options()) :: GenServer.on_start()
  def start_link(module, init_arg, gen_opts) do
    # The starter is handed to init/1: a process started without a link has
    # no OTP "parent", so the module stops itself when the starter exits.
    case GenServer.start(module, {:"$hotkv_owner", self(), init_arg}, gen_opts) do
      {:ok, pid} = ok ->
        Process.link(pid)
        ok

      other ->
        other
    end
  end
end

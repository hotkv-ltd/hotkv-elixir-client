# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.TestSupport do
  @moduledoc false
  # Shared helpers for integration tests: none of this is part of the
  # published package (test/support is not compiled into the library).

  @doc "The HOTKV_TEST_URL environment variable, or raises if unset (only called from :integration tests, which are excluded when it is unset)."
  def test_url do
    System.get_env("HOTKV_TEST_URL") || raise "HOTKV_TEST_URL is not set"
  end

  @doc "Starts a fresh, unlinked connection to the test server."
  def start_conn(extra_opts \\ []) do
    {:ok, conn} = HotKV.start_link(Keyword.merge([url: test_url()], extra_opts))
    conn
  end

  @doc """
  A key/namespace/id prefix unique to this call: concurrent async tests
  never collide, and neither do separate test runs against a persistent,
  shared test server.
  """
  def unique(label) do
    "hkvtest:#{label}:#{System.system_time(:nanosecond)}:#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc """
  Runs `fun.(ok_result)` unless `result` is a `NOLICENSE` error, in which
  case the test is left to pass with a printed skip reason instead of
  running `fun` (the test server's license does not include the feature
  under test; the same test exercises it fully against a server whose
  license includes it).
  """
  def licensed_or_skip({:error, %HotKV.Error{kind: :not_licensed} = error}, _fun) do
    IO.puts("      SKIP (not licensed): #{Exception.message(error)}")
    :ok
  end

  def licensed_or_skip(result, fun), do: fun.(result)
end

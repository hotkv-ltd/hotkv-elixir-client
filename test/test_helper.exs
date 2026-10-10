# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

exclude = if System.get_env("HOTKV_TEST_URL"), do: [], else: [:integration]
# test/integration/remote_test.exs needs a TLS + password server (HOTKV_REMOTE_HOST)
exclude = if System.get_env("HOTKV_REMOTE_HOST"), do: exclude, else: [:remote | exclude]

if :integration in exclude do
  IO.puts(
    "\nHOTKV_TEST_URL not set: skipping integration tests. " <>
      "Set HOTKV_TEST_URL=hotkv://127.0.0.1:PORT to run them.\n"
  )
end

ExUnit.start(exclude: exclude)

# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.MixProject do
  use Mix.Project

  @source_url "https://github.com/hotkv-ltd/hotkv-elixir-client"
  @version "1.0.0"

  def project do
    [
      app: :hotkv,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      name: "HotKV",
      source_url: @source_url,
      homepage_url: "https://hotkv.com",
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {HotKV.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Documentation tooling only (`mix docs`). `only: :dev` keeps it out of
      # the published package's requirements; `optional: true` would be
      # redundant on top of that, so it is not set. ex_doc 0.40 itself needs
      # Elixir 1.15, so `mix docs` is a 1.15+ task even though the library
      # supports Elixir 1.14.
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A high-performance Elixir client for HotKV, a RESP2/RESP3-compatible in-memory data store with built-in AI and LLM-serving features."
  end

  defp package do
    [
      name: "hotkv",
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => "https://hotkv.com",
        "Source" => @source_url
      },
      maintainers: ["HotKV Ltd"],
      files: ~w(lib mix.exs README.md LICENSE NOTICE SECURITY.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "SECURITY.md",
        "LICENSE"
      ],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end

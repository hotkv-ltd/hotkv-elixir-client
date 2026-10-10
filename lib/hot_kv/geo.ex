# Copyright (c) 2026 HotKV Ltd
# Licensed under the Apache License, Version 2.0. See LICENSE in the project root.

defmodule HotKV.Geo do
  @moduledoc "Geospatial commands, built on the sorted set type."

  alias HotKV.{Args, Error, Reply}

  @type conn :: HotKV.conn()
  @type key :: String.t()
  @type coordinate :: float | integer | String.t()

  @doc """
  `GEOADD key [NX|XX] [CH] longitude latitude member [...]` -> the number of
  members newly added. `entries` is `[{longitude, latitude, member}, ...]`.
  """
  @spec geoadd(conn, key, [{coordinate, coordinate, binary}], keyword) ::
          {:ok, integer} | {:error, Error.t()}
  def geoadd(conn, key, entries, opts \\ []) do
    extra =
      [] |> Args.flag(opts, :nx, "NX") |> Args.flag(opts, :xx, "XX") |> Args.flag(opts, :ch, "CH")

    body =
      Enum.flat_map(entries, fn {lon, lat, member} -> [coord_arg(lon), coord_arg(lat), member] end)

    HotKV.command(conn, ["GEOADD", key | extra] ++ body)
  end

  @doc "`GEOPOS key member [member ...]` -> `{longitude, latitude}` per member, `nil` for members not present."
  @spec geopos(conn, key, binary | [binary]) ::
          {:ok, [{float, float} | nil]} | {:error, Error.t()}
  def geopos(conn, key, members) do
    conn
    |> HotKV.command(["GEOPOS", key | List.wrap(members)])
    |> Reply.map(fn list ->
      Enum.map(list, fn
        nil -> nil
        [lon, lat] -> {Reply.to_double(lon), Reply.to_double(lat)}
      end)
    end)
  end

  @doc "`GEODIST key member1 member2 [unit]` -> the distance, `nil` if either member is missing. `unit`: `:m` (default), `:km`, `:mi`, `:ft`."
  @spec geodist(conn, key, binary, binary, atom) ::
          {:ok, float | :inf | :"-inf" | :nan | nil} | {:error, Error.t()}
  def geodist(conn, key, member1, member2, unit \\ :m) do
    conn
    |> HotKV.command(["GEODIST", key, member1, member2, unit_arg(unit)])
    |> Reply.map(&nilable_double/1)
  end

  @doc "`GEOHASH key member [member ...]` -> an 11-character geohash string per member, `nil` for members not present."
  @spec geohash(conn, key, binary | [binary]) :: {:ok, [String.t() | nil]} | {:error, Error.t()}
  def geohash(conn, key, members), do: HotKV.command(conn, ["GEOHASH", key | List.wrap(members)])

  @doc """
  `GEOSEARCH key FROMMEMBER|FROMLONLAT BYRADIUS|BYBOX [ASC|DESC] [COUNT n [ANY]] [WITHCOORD] [WITHDIST] [WITHHASH]`.

  `opts`: `:from_member` or `:from_lonlat` (`{lon, lat}`, required, pick
  one); `:by_radius` (`{radius, unit}`) or `:by_box` (`{width, height,
  unit}`, required, pick one); `:order` (`:asc`/`:desc`); `:count` (`n` or
  `{n, :any}`); `:withcoord`, `:withdist`, `:withhash` (booleans).

  Without any `:with*` option, returns member names. With one or more,
  returns `%{member:, distance:, hash:, coord:}` maps (unset fields `nil`).
  """
  @spec geosearch(conn, key, keyword) :: {:ok, [binary] | [map]} | {:error, Error.t()}
  def geosearch(conn, key, opts \\ []) do
    extra =
      []
      |> add_from(opts)
      |> add_by(opts)
      |> add_order(opts)
      |> add_count(opts)
      |> Args.flag(opts, :withcoord, "WITHCOORD")
      |> Args.flag(opts, :withdist, "WITHDIST")
      |> Args.flag(opts, :withhash, "WITHHASH")

    conn |> HotKV.command(["GEOSEARCH", key | extra]) |> normalize_geosearch(opts)
  end

  @doc """
  `GEOSEARCHSTORE destination source FROMMEMBER|FROMLONLAT BYRADIUS|BYBOX [ASC|DESC] [COUNT n [ANY]] [STOREDIST]`
  -> the number of members stored. `opts` as in `geosearch/3`, plus `:storedist` (boolean).
  """
  @spec geosearchstore(conn, key, key, keyword) :: {:ok, integer} | {:error, Error.t()}
  def geosearchstore(conn, destination, source, opts \\ []) do
    extra =
      []
      |> add_from(opts)
      |> add_by(opts)
      |> add_order(opts)
      |> add_count(opts)
      |> Args.flag(opts, :storedist, "STOREDIST")

    HotKV.command(conn, ["GEOSEARCHSTORE", destination, source | extra])
  end

  defp add_from(acc, opts) do
    case {Keyword.get(opts, :from_member), Keyword.get(opts, :from_lonlat)} do
      {member, _} when is_binary(member) -> acc ++ ["FROMMEMBER", member]
      {_, {lon, lat}} -> acc ++ ["FROMLONLAT", coord_arg(lon), coord_arg(lat)]
      _ -> acc
    end
  end

  defp add_by(acc, opts) do
    case {Keyword.get(opts, :by_radius), Keyword.get(opts, :by_box)} do
      {{radius, unit}, _} ->
        acc ++ ["BYRADIUS", coord_arg(radius), unit_arg(unit)]

      {_, {width, height, unit}} ->
        acc ++ ["BYBOX", coord_arg(width), coord_arg(height), unit_arg(unit)]

      _ ->
        acc
    end
  end

  defp add_order(acc, opts) do
    case Keyword.get(opts, :order) do
      :asc -> acc ++ ["ASC"]
      :desc -> acc ++ ["DESC"]
      _ -> acc
    end
  end

  defp add_count(acc, opts) do
    case Keyword.get(opts, :count) do
      nil -> acc
      {n, :any} -> acc ++ ["COUNT", n, "ANY"]
      n -> acc ++ ["COUNT", n]
    end
  end

  defp normalize_geosearch({:ok, list}, opts) when is_list(list) do
    if Enum.any?([:withcoord, :withdist, :withhash], &Keyword.get(opts, &1)) do
      {:ok, Enum.map(list, &normalize_entry(&1, opts))}
    else
      {:ok, list}
    end
  end

  defp normalize_geosearch(other, _opts), do: other

  defp normalize_entry([member | rest], opts) do
    {dist, rest} = take_if(rest, Keyword.get(opts, :withdist))
    {hash, rest} = take_if(rest, Keyword.get(opts, :withhash))
    {coord, _rest} = take_if(rest, Keyword.get(opts, :withcoord))
    %{member: member, distance: nilable_double(dist), hash: hash, coord: geo_pair(coord)}
  end

  defp take_if([value | rest], true), do: {value, rest}
  defp take_if(rest, _falsy), do: {nil, rest}

  defp geo_pair(nil), do: nil
  defp geo_pair([lon, lat]), do: {Reply.to_double(lon), Reply.to_double(lat)}

  defp nilable_double(nil), do: nil
  defp nilable_double(value), do: Reply.to_double(value)

  defp unit_arg(unit) when is_atom(unit), do: Atom.to_string(unit)
  defp unit_arg(unit), do: unit

  defp coord_arg(value) when is_float(value), do: HotKV.Numeric.format_float(value)
  defp coord_arg(value), do: value
end

# HotKV Elixir Client

[![CI](https://github.com/hotkv-ltd/hotkv-elixir-client/actions/workflows/ci.yml/badge.svg)](https://github.com/hotkv-ltd/hotkv-elixir-client/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A high-performance Elixir client for [HotKV](https://hotkv.com), a RESP2/RESP3-compatible
in-memory data store with built-in AI and LLM-serving features (semantic and prompt
caching, agent memory, RAG, feature store, rate limiting, time series and more).

## Requirements

* Elixir 1.14 or newer (CI runs 1.14.5 on OTP 25.3 and 1.16.2 on OTP 26.2).
* OTP 25 or newer for TLS with the operating system's CA store. On OTP 24,
  give `tls_opts: [ca_file: ...]` explicitly.
* A HotKV server (the SDK is verified against HotKV v0.3.0).

## Install

Add `hotkv` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:hotkv, "~> 1.0"}
  ]
end
```

This package has zero runtime dependencies.

## Quick start

```elixir
{:ok, conn} = HotKV.start_link(url: "hotkv://127.0.0.1:6379")

{:ok, "OK"} = HotKV.command(conn, ["SET", "greeting", "hello"])
{:ok, "hello"} = HotKV.command(conn, ["GET", "greeting"])

# Typed wrapper modules build the raw command for you and normalize the
# reply (RESP2 and RESP3 shapes are both handled transparently):
{:ok, "hello"} = HotKV.Strings.get(conn, "greeting")
{:ok, "OK"} = HotKV.Strings.set(conn, "greeting", "hi", ex: 60)
```

Under a supervisor, registered under a name:

```elixir
children = [
  {HotKV, url: "hotkv://127.0.0.1:6379", name: MyApp.HotKV}
]

HotKV.Strings.get(MyApp.HotKV, "greeting")
```

## Connection options

`HotKV.start_link/1` (and `HotKV.Pool.start_link/1`, `HotKV.Cluster.start_link/1`,
`HotKV.PubSub.start_link/1`) accept:

- `:url` - `hotkv://[user:pass@]host[:port][/db]`. `hotkvs://` enables TLS.
  `redis://`/`rediss://` are accepted too, for drop-in migration.
  `unix:///path/to/socket[?database=N]` connects over a Unix domain socket.
- `:host`, `:port`, `:unix_socket`, `:username`, `:password`, `:database` -
  set directly instead of (or to override) the URL.
- `:client_name` - sent via `HELLO ... SETNAME`.
- `:connect_timeout`, `:command_timeout` - milliseconds (default `5000`).
- `:resp3` - defaults to `true` (`HELLO 3`, with automatic fallback to
  RESP2 if the server rejects it).
- `:tls` - `true` to enable TLS (implied by `hotkvs://`/`rediss://`).
- `:tls_opts` - a keyword list: `:ca_file`, `:cert_file` / `:key_file`
  (mutual TLS), `:server_name` (the name to verify the certificate for, and
  to send as SNI; an IP address is verified against the certificate's IP
  entries), `:insecure_skip_verify` (disables certificate verification;
  tests only, never in production). `:ca_file` may be a CA bundle or the
  server's own self-signed certificate.
- `:name` - registers the process, any GenServer name.

```elixir
{:ok, conn} =
  HotKV.start_link(
    url: "hotkvs://cache.internal:6379",
    username: "app",
    password: System.fetch_env!("HOTKV_PASSWORD"),
    tls_opts: [ca_file: "/etc/ssl/certs/hotkv-ca.pem"]
  )
```

## Pooling

```elixir
{:ok, pool} = HotKV.Pool.start_link(url: "hotkv://127.0.0.1:6379", size: 10)

HotKV.command(pool, ["PING"])
HotKV.Strings.get(pool, "greeting")
```

Under a supervisor, `{HotKV.Pool, name: MyApp.Pool, url: ..., size: 10}` is
a child spec; use `HotKV.Pool.handle(MyApp.Pool)` to get the value to pass
to `HotKV.command/3` and friends.

`HotKV.Pool` checks out the next connection (round-robin) for each call.
It accepts a `HotKV.Pool` wherever it accepts a plain connection, including
every typed wrapper module. A connection that crashes is restarted
automatically.

## Pipelines

```elixir
{:ok, results} =
  HotKV.pipeline(conn, [
    ["SET", "a", "1"],
    ["INCR", "a"],
    ["GET", "a"]
  ])

results == [{:ok, "OK"}, {:ok, 2}, {:ok, "2"}]
```

One round trip; each command's own result is `{:ok, value} | {:error,
reason}`, so one failing command never fails the rest of the batch.

## Transactions

```elixir
{:ok, "OK"} = HotKV.watch(conn, ["balance:alice"])

{:ok, results} =
  HotKV.transaction(conn, fn c ->
    HotKV.command(c, ["DECRBY", "balance:alice", "10"])
    HotKV.command(c, ["INCRBY", "balance:bob", "10"])
  end)

case results do
  nil -> :aborted_because_balance_alice_changed
  [_decr_result, _incr_result] -> :ok
end
```

`transaction/3` sends `MULTI`, calls your function (whose commands get back
`"QUEUED"`, not their real result), then `EXEC`. It returns `{:ok, nil}` if
a watched key changed first. Use `HotKV.command/3` (not the typed wrapper
modules) for commands issued inside the transaction function, since typed
wrappers normalize a real reply shape that `"QUEUED"` does not match.
Passing a `HotKV.Pool` checks out one connection for the whole transaction.

## Pub/Sub

```elixir
{:ok, pubsub} = HotKV.PubSub.start_link(url: "hotkv://127.0.0.1:6379")
:ok = HotKV.PubSub.subscribe(pubsub, ["news"])

receive do
  {:hotkv_pubsub, ^pubsub, :message, %{channel: "news", payload: payload}} ->
    IO.puts(payload)
end
```

`HotKV.PubSub.psubscribe/3` (glob patterns, delivers `:pmessage`) and
`HotKV.PubSub.ssubscribe/3` (shard channels via `SSUBSCRIBE`/`SPUBLISH`,
delivers `:smessage`) work the same way. Multiple local processes can
subscribe through the same `HotKV.PubSub`; each gets every message for the
channels/patterns it subscribed to. A dropped connection re-subscribes to
everything automatically once it reconnects.

## Cluster

```elixir
{:ok, cluster} = HotKV.Cluster.start_link(seeds: ["10.0.0.1:6379", "10.0.0.2:6379"])

HotKV.Cluster.command(cluster, ["GET", "foo"])
```

Builds a slot map from `CLUSTER SLOTS`, routes by key (CRC16, with
`{hash tag}` support), and follows `MOVED` (refreshing the slot map) and
`ASK` (sending `ASKING` first) redirects, up to `:max_redirects` hops
(default 5). The routing key is the command's second argument by default;
pass `key: "..."` in `opts` for commands shaped differently.

## HotKV exclusive commands

These HotKV-exclusive command families have a typed module: `HotKV.Tag`,
`HotKV.NanoTTL` (nanosecond TTLs), `HotKV.HotKeys`, `HotKV.Gcra`,
`HotKV.Vsim` (vector similarity), `HotKV.RateLimit`, `HotKV.TimeSeries`,
`HotKV.FeatureStore`, `HotKV.Observe`, `HotKV.Alerts`, and
the AI command families below. The HotKV-exclusive `SET key value IFEQ/IFNE/IFDEQ/IFDNE`
conditions (`HotKV.Strings.set/4`), `DIGEST` and `DELEX` are typed as well.

Not typed (send them with `HotKV.command/3`): `TENANT.*`, `IAM.*`,
`AUDIT.*`, `ENCRYPTION.*`, `REPLICATION.*` and the replication-internal
`*.SYNC` / `FEATURE.SETAT`; `BF.*`, `CMS.*` and `TOPK.*`; `HIMPORT`.

```elixir
{:ok, tenants} = HotKV.command(conn, ["TENANT.LIST"])
```

```elixir
HotKV.Tag.set(conn, "user:42", ["premium", "beta"])
HotKV.Tag.members(conn, "premium")

HotKV.NanoTTL.nexpire(conn, "lock:42", 500_000_000)

HotKV.Vsim.createindex(conn, "docs", 384)
HotKV.Vsim.set(conn, "docs", "doc1", embedding)
HotKV.Vsim.search(conn, "docs", 5, query_embedding)
```

## Command coverage

The SDK has typed functions for 228 of the 428 core commands and 144 of
the 177 enterprise commands of HotKV v0.3.0. Every typed function is
called by a live integration test. The other commands
are sent with the generic `HotKV.command/3`, which takes any argument list and returns the
decoded reply. These have **no** typed function (the list is not
exhaustive):

* client-side caching and connection control: `CLIENT TRACKING`,
  `CLIENT CACHING`, `CLIENT GETREDIR`, `CLIENT TRACKINGINFO`, `CLIENT LIST`,
  `CLIENT KILL`, ... (invalidation pushes are not delivered to the
  application), `MONITOR`;
* `ACL *`, `CLUSTER *` (except the `CLUSTER SLOTS` that `HotKV.Cluster` uses),
  `READONLY` / `READWRITE`, `SFLUSH`, `CLUSTERSCAN`, `TRIMSLOTS`;
* the `BF.*`, `CMS.*` and `TOPK.*` probabilistic structures, `HIMPORT`;
* `TENANT.*`, `IAM.*`, `AUDIT.*`, `ENCRYPTION.*`, `REPLICATION.*`;
* the `FUNCTION *`, `SORT`, `LCS`, `LMPOP`/`BLMPOP`/`ZMPOP`/`BZMPOP`,
  `BZPOPMIN`/`BZPOPMAX`, `BRPOPLPUSH`, `HMSET`, `GEORADIUS*`, `OBJECT
  FREQ|IDLETIME|REFCOUNT`, `SLOWLOG`, `MEMORY`, `LATENCY`, `SAVE`/`BGSAVE`,
  `SWAPDB`, `WAIT` family.

`HotKV.Cluster` routes every command to the master that owns its slot and
follows `MOVED`/`ASK`; reading from replicas (`READONLY`) is not supported.
Cluster support has unit tests with fake servers but was not verified
against a running cluster.

## Numbers on the wire

Every float argument is sent as a plain decimal (`0.00001`, never
`1.0e-5`; see `HotKV.Numeric`), because several server parsers reject an
exponent. `LLMBUDGET.SET` and `LLMSTATS.PRICE SET` read an exact USD amount
with at most 6 decimals, so floats passed to them are rounded to 6 decimals;
pass a string such as `"0.000001"` to send an exact decimal. `:inf` and
`:"-inf"` are sent as `inf` / `-inf`; `nil`, `:nan` and terms with no wire
form raise `ArgumentError` in the calling process.

## AI commands

Raw command wrappers: `HotKV.SemanticCache` (`SCACHE.*`), `HotKV.PromptCache`
(`PCACHE.*`), `HotKV.ToolCache`, `HotKV.NegativeCache`, `HotKV.GuardCache`,
`HotKV.RerankCache`, `HotKV.LLMStats`, `HotKV.LLMBudget`,
`HotKV.PromptRegistry`, `HotKV.EmbedDedup`, `HotKV.AgentMemory`, `HotKV.RAG`.

On top of those, `HotKV.AI.PromptCache` and `HotKV.AI.SemanticCache` are
idiomatic get-or-call caches: the wrapped function only runs on a cache
miss.

```elixir
prompt_cache = HotKV.AI.PromptCache.new(conn, "chat_cache", ttl: 3600, stats_bucket: "chat")
:ok = HotKV.AI.PromptCache.create_namespace(prompt_cache)

{:ok, reply, hit?} =
  HotKV.AI.PromptCache.get_or_call(
    prompt_cache,
    %{
      provider: "openai",
      model: "gpt-4",
      messages: [%{role: "user", content: "Summarize this quarter's revenue."}],
      params: %{"temperature" => "0.2"}
    },
    fn ->
      # This function only runs on a cache miss.
      response = call_openai(...)

      {:ok, response.text,
       %{input_tokens: response.usage.input, output_tokens: response.usage.output, cost_usd: 0.0031}}
    end
  )

if hit?, do: Logger.debug("prompt cache hit"), else: Logger.debug("prompt cache miss, called the LLM")
```

The cache key (`HotKV.AI.PromptCacheKey.build/1`) is a deterministic,
sorted-key JSON encoding of the request, SHA-256 hashed: every official
HotKV SDK computes it the same way, so the same logical request produces
the same key in every language.

`HotKV.AI.SemanticCache` looks up the nearest cached answer to an embedding
vector above a similarity threshold, calling your function only when
nothing is close enough; it never computes embeddings itself, so it works
with any provider's embedding model:

```elixir
semantic_cache = HotKV.AI.SemanticCache.new(conn, "faq_cache", ttl: 86_400)
:ok = HotKV.AI.SemanticCache.create_namespace(semantic_cache, 1536)

{:ok, answer, hit?} =
  HotKV.AI.SemanticCache.get_or_call(semantic_cache, question, embed(question), fn ->
    {:ok, call_llm(question)}
  end)
```

## LLM cost tracking

A `HotKV.TokenUsage` records one model call's tokens; pass it (as
`usage: ...`) to `PCACHE.SET`, `SCACHE.SET`, any keyed cache `SET` or
`LLMBUDGET.CONSUME`, and a later cache hit attributes the tokens, and
once the model is priced its exact cost, to that namespace's
`usage_saved_*` stats:

```elixir
usage = HotKV.TokenUsage.new("claude-sonnet-5", input_tokens: 120, output_tokens: 40)
{:ok, "OK"} = HotKV.PromptCache.set(conn, "chat-v1", prompt, response, usage: usage)

# ... later, on a cache hit:
{:ok, stats} = HotKV.PromptCache.stats(conn, "chat-v1")

IO.puts(
  "saved #{stats["usage_saved_requests"]} calls, " <>
    "$#{stats["usage_saved_cost_usd"]} once the model is priced"
)
```

`LLMSTATS.RECORD` accepts the same `:model` option so its cost is computed
from the price table instead of a manually tracked `cost_usd`:

```elixir
HotKV.LLMStats.bucket(conn, "chat-v1")
HotKV.LLMStats.record(conn, "chat-v1", 120, 40, 0, 0, 812, model: "claude-sonnet-5")
```

Custom models (or a price override for a built-in one) go through
`LLMSTATS.PRICE SET`, USD per 1,000,000 tokens:

```elixir
{:ok, "OK"} = HotKV.LLMStats.price_set(conn, "my-finetuned-model", 2, 10)
{:ok, price} = HotKV.LLMStats.price_get(conn, "my-finetuned-model")
price.source
# => "custom"
```

`LLMBUDGET.CONSUME` takes the same usage value so a budget's token count
and cost are both derived from the price table:

```elixir
{:ok, allowed} = HotKV.LLMBudget.consume(conn, "team-a", 0, 0, usage)
```

## Error handling

Every function returns `{:ok, value} | {:error, %HotKV.Error{}}` (and a
bang variant that returns `value` directly, raising `HotKV.Error` on
failure). `HotKV.Error` is a proper `Exception`, with a `:kind`:

- `:connection` - could not establish or maintain the connection.
- `:timeout` - no reply within the command's timeout.
- `:protocol` - the server sent bytes that do not parse as RESP2/RESP3.
- `:server` - a RESP error reply; `:prefix` holds its leading token
  (`"WRONGTYPE"`, `"NOAUTH"`, `"ERR"`, ...).
- `:not_licensed` - a `NOLICENSE` reply: the connected license does not
  include the feature the command needs. Check with
  `HotKV.Error.not_licensed?/1`.
- `:cluster_redirect` - a `MOVED`/`ASK` reply (`HotKV.Cluster` follows
  these itself; you only see this kind if redirects are exhausted).

```elixir
case HotKV.PromptCache.get(conn, "cache_ns", key) do
  {:ok, response} -> response
  {:error, %HotKV.Error{kind: :not_licensed}} -> call_llm_directly()
  {:error, %HotKV.Error{kind: :server, prefix: "WRONGTYPE"}} -> handle_wrong_type()
  {:error, error} -> raise error
end
```

Idempotent reads (`GET`, `HGETALL`, `EXISTS`, ...) are retried once
automatically after a connection loss; non-idempotent writes are not,
unless you pass `retry: true`.

## Testing

```
mix test
```

runs the unit tests (RESP codec, number formatting, URL/option parsing,
CRC16, cache key determinism, exact request bytes of the typed wrappers,
timeouts and cluster redirects against fake servers), which need no
server. To also run the integration tests against a live HotKV server:

```
HOTKV_TEST_URL=hotkv://127.0.0.1:6379 mix test
```

The integration tests do not flush the server and namespace their keys,
but point them at a throwaway instance. Tests for commands the server's
license does not include detect the `NOLICENSE` reply and **pass** with a
printed `SKIP (not licensed)` line, so a green run on an unlicensed server
does not verify the enterprise families; run against a licensed server for
that. Optional variables: `HOTKV_TEST_FLUSHALL_URL` (a disposable server;
enables the `FLUSHALL` test) and the `HOTKV_REMOTE_*`
variables of `test/integration/remote_test.exs` (a TLS + password server
reached over the network).

CI runs the unit tests and the package and documentation builds only: the
HotKV server is a commercial binary that CI cannot download.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

- Bugs and feature requests: [GitHub issues](https://github.com/hotkv-ltd/hotkv-elixir-client/issues)
- Questions and commercial support: support@hotkv.com
- Security vulnerabilities: see [SECURITY.md](SECURITY.md)

## License

Licensed under the Apache License, Version 2.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Trademarks and affiliation

"HotKV" is a trademark of HotKV Ltd; the license does not grant rights to use it.
The HotKV server is a separate commercial product, and its enterprise commands need a HotKV license.

HotKV is an independent product of HotKV Ltd. It speaks the RESP protocol and implements
many Redis commands so that existing tools and client habits carry over, but it is not Redis,
Valkey, Dragonfly or KeyDB, and this SDK is built for and tested against HotKV. HotKV Ltd is not
affiliated with, endorsed by or sponsored by Redis Ltd., the Valkey project, DragonflyDB or KeyDB.
Redis is a registered trademark of Redis Ltd. Valkey, Dragonfly, KeyDB and all other product and
company names are trademarks of their respective owners; they are used here only to describe
protocol and command compatibility.

# Fix compiler warnings and a KeyError in Socket.Web.accept/2

Three small fixes, so that `mix compile --warnings-as-errors` — which this
repository's CI already runs — passes again on recent Elixir. One of them is a
crash, not just a warning.

- **`Socket.Helpers.bang/1`** now does the `:ok | {:ok, _} | {:error, _}`
  unwrapping that `defbang` used to inline at each call site. Behind a function
  boundary, the compiler no longer flags dead clauses in `Socket.TCP.accept!/1`,
  `accept!/2`, `Socket.Port.open!/1` and `open!/2`.

- **`Socket.Web.accept/2`** returns `{:error, e.message}` on a `Socket.Error`,
  matching what `connect/3` already did. It used `e.code`, a key that exception
  does not have, so `Socket.Web.accept(listener, timeout: 50)` raised
  `KeyError`. A new test covers it.

- **`Socket.Web.connect/3`** drops its `rescue` on `Socket.TCP.Error` and
  `Socket.SSL.Error`. Neither module exists in this library, and those
  transports raise `Socket.Error`, which the clause above already catches.

No renaming, no reformatting, no other behaviour change.

Verified on Elixir 1.18.3 / OTP 26: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test` (12 tests, 0 failures).

Unrelated, but worth knowing: `test "env" (PortTest)` is flaky on `master`
(about 1 run in 15). If CI goes red there, it is not this change.

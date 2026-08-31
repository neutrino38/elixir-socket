# Fix two crashes in Socket.Web on frames the RFC allows

Two small fixes in `lib/socket/web.ex`, each with a test that fails without it.
Both are crashes on input a well-behaved peer, or a caller reading the docs, can
produce.

- **`forge/2` now treats `false` as "do not mask".** `send/3` and `close/3`
  document a `mask:` option, and `mask: false` is how a caller says the frame
  goes out unmasked — which RFC 6455 §5.3 requires of a server. `forge/2` only
  had a clause for `nil` and one for an integer key, so `false` fell into the
  key clause and reached `Bitwise.bxor/2`:
  `Socket.Web.send!(socket, {:text, "x"}, mask: false)` raised
  `ArithmeticError`.

- **`close_code/1` now accepts any integer code.** RFC 6455 §7.4.2 leaves
  3000-4999 to applications and libraries. The function is used on both sides of
  the wire: `Socket.Web.close(socket, {4000, "bye"})` raised
  `FunctionClauseError`, and so did reading a peer's clean close carrying such a
  code — which kills the reader on a healthy connection.

Adds `test/web_test.exs`, the first test file for `Socket.Web`: a harness that
binds the listener before starting the server task, and five tests covering a
binary round trip, an unmasked send, a fragmented message, an application close
code and a registered one.

Both fixes bite. Restoring `forge(nil, data)` fails the unmasked-send test with
`ArithmeticError`; removing the `close_code/1` clause fails the 4000 test with
`FunctionClauseError`.

Widening two patterns, nothing narrowed, no behaviour change on any input that
worked before.

Verified on Elixir 1.18.3 / OTP 26: `mix format --check-formatted` passes,
`mix test` is 16 tests / 0 failures. `mix compile --warnings-as-errors` still
fails on this branch, with exactly the warnings `master` already has — the same
nine, at the same sites, shifted by the four lines added here. Nothing new.

Unrelated, but worth knowing: `test "env"` (`PortTest`) and
`test "connect ping"` (`SocketTest`) are flaky on `master` — 5 red runs out of
25 measured here, `** (Socket.Error) connection refused` in both. If CI goes red
there, it is not this change.

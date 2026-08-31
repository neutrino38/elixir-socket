# Parse an IPv6 literal written inside brackets

`Socket.Address.parse/1` answered `nil` on `"[::1]"`.

That is the form a URI authority and a `Host` header carry an IPv6 literal in
(RFC 3986 §3.2.2), so it is the form a caller holding an address taken from a
URI has in hand. Every such caller had to strip the brackets itself, and the one
who forgot dialed the wrong address family with no diagnostic — the address just
looked like a host name that does not resolve.

The new clause reads the reference and delegates to the existing parser. Only a
v6 address is written that way, so `"[127.0.0.1]"` stays `nil`, and so does a
bracket that never closes.

Adds `test/ipv6_test.exs` with one test, over both the accepted and the rejected
spellings. It bites: without the clause, `parse("[::1]")` returns `nil` and the
test fails.

Twelve lines, one new clause, nothing narrowed — `parse/1` now answers on an
input where it used to answer `nil`.

Verified on Elixir 1.18.3 / OTP 26: `mix format --check-formatted` passes,
`mix test` is 12 tests / 0 failures. `mix compile --warnings-as-errors` still
fails on this branch, with exactly the nine warnings `master` already has, at
the same sites. Nothing new here.

Unrelated, but worth knowing: `test "env"` (`PortTest`) and
`test "connect ping"` (`SocketTest`) are flaky on `master` — 5 red runs out of
25 measured here, `** (Socket.Error) connection refused` in both. If CI goes red
there, it is not this change.

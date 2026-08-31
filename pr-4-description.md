# An IP literal is an address, not a host name

**Depends on #7** (`Socket.Address.parse/1` on an IPv6 reference). This branch
sits on top of it, and one of the tests here dials the bracketed form `"[::1]"`
that #7 teaches `parse/1`.

`Socket.TCP.connect/3` takes an address in every form `Socket.Address.t()`
covers: a tuple, a literal such as `"::1"` or `"127.0.0.1"`, the bracketed
`"[::1]"`, or a host name.

A literal reaches `:gen_tcp.connect/4` as a tuple. The tuple carries its own
family, so the call needs no resolution at all and cannot land in the wrong one.
Only a real host name travels as a charlist, and only it goes to the resolver.

`Socket.SSL.connect/3` gets the same treatment, in one line.

The `@spec` of `Socket.TCP.connect/3` and `connect!/3` now reads
`Socket.Address.t()`: the type the code accepts.

## Tests

Two tests in `test/ipv6_test.exs`, both against a listener bound on `::1`. Both
fail without the change.

- **TCP** dials the same peer three ways — `"::1"`, `"[::1]"`, and the tuple —
  and expects a connection each time.
- **SSL** reads a failure, since no TLS server answers on the other end. It
  asserts the connection was made and the handshake ran out of time
  (`{:error, :timeout}`), and refutes `:nxdomain`, which is the resolver's
  answer and not the socket's. Testing it with a real TLS server would need the
  PKI that comes with a later PR.

## Risk

Low, but real: a caller whose host **name** looks like an IP address takes the
address path. In practice no host name looks like an IP address.

Verified on Elixir 1.18.3 / OTP 26: `mix format --check-formatted` passes,
`mix test` is 14 tests / 0 failures. `mix compile --warnings-as-errors` still
fails, with exactly the nine warnings `master` already has, at the same sites.
Nothing new here.

Unrelated, but worth knowing: `test "env"` (`PortTest`) and
`test "connect ping"` (`SocketTest`) are flaky on `master` — 5 red runs out of
25 measured here, `** (Socket.Error) connection refused` in both. If CI goes red
there, it is not this change.

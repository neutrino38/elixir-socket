# Datagrams sent to an IP literal, and a v6only switch for UDP

**Base.** This branch sits on the TCP/SSL literal PR, which itself sits on #7.
Take the three in that order.

Two changes, one commit each.

**`Socket.Datagram.send/3` takes a destination in every form
`Socket.Address.t()` covers**: a tuple, a literal such as `"::1"`, the bracketed
`"[::1]"` that a URI authority or a `Host` header carries, or a host name. A
literal is sent as a tuple. Only a real host name is resolved.

**`Socket.UDP.open/2` takes `v6only: true | false`**, which sets the socket's
`ipv6_v6only`. One `open/2` call now expresses the family, the bind address and
this switch. 

## Tests

Two tests in `test/ipv6_test.exs` are added

Elixir 1.18.3 / OTP 26: `mix format --check-formatted` passes, `mix test` is 16
tests / 0 failures over four runs, and `mix compile --warnings-as-errors` fails
with exactly the nine warnings `master` already has, at the same sites.


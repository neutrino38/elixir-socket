# Host header: brackets around an IPv6 address

**Base.** Merge order: #7, then the TCP/SSL literal PR, then the UDP PR, then
this one.

The handshake now sends `Host: [::1]:443`. RFC 3986 §3.2.2 requires the
brackets: they tell the peer where the address ends and the port begins.

New function `Socket.Address.to_uri_host/1` adds them and prints the canonical
form (RFC 5952). IPv4 addresses and host names come back unchanged, so nothing
moves outside IPv6. `Socket.Web.connect/3` is its only caller, and arrives with
it.

## Tests

Two in `test/ipv6_test.exs`, both measured to bite.

- `to_uri_host/1` over a tuple, a string, a charlist, a bracketed string, IPv4,
  a host name, and `2001:DB8:0:0:0:0:0:1` for the canonical form.
- A handshake against a listener bound on `::1`. The server sends back the
  `Host` header it read. Revert the `web.ex` line and the test fails:
  `"::1:33845"` against `"[::1]:33845"`.

Elixir 1.18.3 / OTP 26: `mix format --check-formatted` passes, `mix test` is 18
tests / 0 failures over four runs, `mix compile --warnings-as-errors` fails with
the nine warnings `master` already has and no others.

`test "env"` (`PortTest`) and `test "connect ping"` (`SocketTest`) are flaky on
`master`: 5 red runs out of 25 here. A red CI there is not this change.

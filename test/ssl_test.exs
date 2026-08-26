defmodule Socket.SSLTest do
  use ExUnit.Case

  @loopback {127, 0, 0, 1}

  test "transport_accept takes a connection without handshaking it" do
    listener = Socket.SSL.listen!(0, local: [address: @loopback])
    {_ip, port} = Socket.local!(listener)

    # A plain TCP client: it connects, and then says nothing at all. The TLS
    # handshake can therefore never complete.
    Task.start_link(fn ->
      _client = Socket.TCP.connect!(@loopback, port)
      Process.sleep(5_000)
    end)

    assert {:ok, accepted} = Socket.SSL.transport_accept(listener, timeout: 2_000)

    # The wait for the client is over and the handshake has not started, so it
    # can be bounded on its own — here it runs out, and only it.
    assert {:error, :timeout} = Socket.SSL.handshake(accepted, timeout: 200)

    Socket.close(listener)
  end

  test "transport_accept times out on an idle listener without touching the handshake" do
    listener = Socket.SSL.listen!(0, local: [address: @loopback])

    assert {:error, :timeout} = Socket.SSL.transport_accept(listener, timeout: 200)

    Socket.close(listener)
  end
end

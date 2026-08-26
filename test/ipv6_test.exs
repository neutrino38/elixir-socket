defmodule Socket.IPv6Test do
  use ExUnit.Case

  @v6 {0, 0, 0, 0, 0, 0, 0, 1}

  test "a URI authority brackets an IPv6 literal and nothing else" do
    assert Socket.Address.to_uri_host(@v6) == "[::1]"
    assert Socket.Address.to_uri_host("::1") == "[::1]"
    assert Socket.Address.to_uri_host(~c"::1") == "[::1]"
    assert Socket.Address.to_uri_host("[::1]") == "[::1]"
    assert Socket.Address.to_uri_host({127, 0, 0, 1}) == "127.0.0.1"
    assert Socket.Address.to_uri_host("127.0.0.1") == "127.0.0.1"
    assert Socket.Address.to_uri_host("example.com") == "example.com"
    # The rendering is canonical (RFC 5952), not the caller's spelling.
    assert Socket.Address.to_uri_host("2001:DB8:0:0:0:0:0:1") == "[2001:db8::1]"
  end

  test "an IPv6reference parses as the address it names" do
    assert Socket.Address.parse("[::1]") == @v6
    assert Socket.Address.parse("::1") == @v6
    assert Socket.Address.valid?("[2001:db8::1]")
    # Only a v6 address is written inside brackets, and the brackets must close.
    assert Socket.Address.parse("[127.0.0.1]") == nil
    assert Socket.Address.parse("[::1") == nil
    assert Socket.Address.parse("[::1]x") == nil
    assert Socket.Address.parse("example.com") == nil
  end

  test "a datagram reaches an IPv6 peer named as a tuple, a string or a reference" do
    {:ok, server} = :gen_udp.open(0, [:binary, {:ip, @v6}, {:active, false}])
    {:ok, {_ip, port}} = :inet.sockname(server)
    client = Socket.UDP.open!(0, mode: :passive, local: [address: @v6])

    for target <- [@v6, "::1", "[::1]"] do
      assert Socket.Datagram.send(client, "ping", {target, port}) == :ok,
             "sending to #{inspect(target)} failed"

      assert {:ok, {_, _, "ping"}} = :gen_udp.recv(server, 0, 1_000)
    end

    :gen_udp.close(client)
    :gen_udp.close(server)
  end

  test "TCP reaches an IPv6 peer named as a reference too" do
    listener = Socket.TCP.listen!(0, local: [address: @v6], version: 6)
    {_ip, port} = Socket.local!(listener)

    assert {:ok, client} = Socket.TCP.connect("[::1]", port, timeout: 1_000)
    Socket.close(client)
    Socket.close(listener)
  end

  test "TCP reaches an IPv6 literal given as a string or as a tuple" do
    listener = Socket.TCP.listen!(0, local: [address: @v6], version: 6)
    {_ip, port} = Socket.local!(listener)

    assert {:ok, from_string} = Socket.TCP.connect("::1", port, timeout: 1_000)
    assert {:ok, from_tuple} = Socket.TCP.connect(@v6, port, timeout: 1_000)

    Socket.close(from_string)
    Socket.close(from_tuple)
    Socket.close(listener)
  end

  test "a WebSocket handshake carries a bracketed Host over IPv6" do
    listener = Socket.Web.listen!(0, local: [address: @v6], version: 6)
    {_ip, port} = Socket.local!(listener)

    Task.start_link(fn ->
      client = Socket.Web.accept!(listener)
      Socket.Web.accept!(client)
      Socket.Web.send!(client, Socket.Web.recv!(client))
    end)

    socket = Socket.Web.connect!("::1", port)
    Socket.Web.send!(socket, {:text, "v6"})
    assert Socket.Web.recv!(socket) == {:text, "v6"}
  end
end

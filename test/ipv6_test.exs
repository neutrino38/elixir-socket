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

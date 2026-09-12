defmodule Socket.WebHandshakeTest do
  use ExUnit.Case, async: true

  @request "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
             "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n"

  defp listen do
    listener = Socket.Web.listen!(0)
    {_ip, port} = Socket.Web.local!(listener)
    {listener, port}
  end

  # The server side of one handshake. The process stays alive once it has its
  # verdict, as an acceptor does: a socket left open shows as left open.
  defp accepting(listener, options \\ []) do
    test = self()
    ref = make_ref()

    spawn_link(fn ->
      Kernel.send(test, {ref, Socket.Web.accept(listener, options)})
      Process.sleep(:infinity)
    end)

    ref
  end

  defp verdict(ref) do
    assert_receive {^ref, verdict}, 5_000
    verdict
  end

  # A raw TCP client that sends `request` to the listener.
  defp raw_client(port, request) do
    client = Socket.TCP.connect!("localhost", port)
    Socket.Stream.send!(client, request)
    client
  end

  defp response(client) do
    {:ok, data} = Socket.Stream.recv(client, timeout: 1_000)
    data
  end

  defp closed?(client), do: Socket.Stream.recv(client, timeout: 1_000) == {:ok, nil}

  # A raw TCP server that swallows one request, then runs `reply` on the socket.
  defp raw_server(reply) do
    listener = Socket.TCP.listen!(0)
    {_ip, port} = Socket.local!(listener)

    Task.start_link(fn ->
      client = Socket.TCP.accept!(listener)
      Socket.TCP.options!(client, packet: :line)
      Stream.repeatedly(fn -> Socket.Stream.recv!(client) end) |> Enum.find(&(&1 == "\r\n"))
      Socket.TCP.options!(client, packet: :raw)
      reply.(client)
      Process.sleep(:infinity)
    end)

    port
  end

  describe "a server rejects" do
    test "a client that stalls inside the headers, once the timeout given to accept is up" do
      {listener, port} = listen()
      ref = accepting(listener, timeout: 300)
      client = raw_client(port, "GET / HTTP/1.1\r\nHost: x\r\n")

      assert verdict(ref) == {:error, "timeout"}
      assert closed?(client)
    end

    test "a request that is not a GET over HTTP/1.1, with a 400" do
      for request <- [
            "POST / HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n",
            String.replace(@request, "HTTP/1.1", "HTTP/1.0"),
            "\x00\x01garbage\r\n\r\n"
          ] do
        {listener, port} = listen()
        ref = accepting(listener)
        client = raw_client(port, request)

        assert verdict(ref) == {:error, "malformed upgrade request"}
        assert response(client) =~ ~r"^HTTP/1.1 400 "
        assert closed?(client)
      end
    end

    test "a request without an Upgrade header, with a 400" do
      {listener, port} = listen()
      ref = accepting(listener)

      client =
        raw_client(
          port,
          "GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nSec-WebSocket-Key: a\r\n\r\n"
        )

      assert verdict(ref) == {:error, "malformed upgrade request"}
      assert response(client) =~ ~r"^HTTP/1.1 400 "
    end

    test "a request without a key, with a 400" do
      {listener, port} = listen()
      ref = accepting(listener)

      client =
        raw_client(
          port,
          "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        )

      assert verdict(ref) == {:error, "missing key"}
      assert response(client) =~ ~r"^HTTP/1.1 400 "
    end

    test "a version other than 13, with a 426 that names 13" do
      {listener, port} = listen()
      ref = accepting(listener)

      client =
        raw_client(port, String.replace(@request, "Sec-WebSocket-Version: 13\r\n", ""))

      assert verdict(ref) == {:error, "unsupported version"}
      reply = response(client)
      assert reply =~ ~r"^HTTP/1.1 426 "
      assert reply =~ "Sec-WebSocket-Version: 13\r\n"
    end

    test "more than 100 headers, with a 431" do
      {listener, port} = listen()
      ref = accepting(listener)

      headers = for i <- 1..101, do: "X-#{i}: y\r\n"
      client = raw_client(port, ["GET / HTTP/1.1\r\n", headers, "\r\n"])

      assert verdict(ref) == {:error, "too many headers"}
      assert response(client) =~ ~r"^HTTP/1.1 431 "
      assert closed?(client)
    end

    # inet drops the connection on an over-long line before any status can
    # be sent: the peer sees the socket close, and nothing else.
    test "a header line over 8 KiB" do
      {listener, port} = listen()
      ref = accepting(listener)

      client =
        raw_client(port, ["GET / HTTP/1.1\r\nCookie: ", :binary.copy("c", 8_193), "\r\n\r\n"])

      assert verdict(ref) == {:error, "header line too long"}
      assert closed?(client)
    end

    test "a request line over 8 KiB" do
      {listener, port} = listen()
      ref = accepting(listener)

      client = raw_client(port, ["GET /", :binary.copy("p", 8_193), " HTTP/1.1\r\n\r\n"])

      assert verdict(ref) == {:error, "request line too long"}
      assert closed?(client)
    end

    test "a key that is not 16 bytes in base64, with a 400" do
      for key <- ["a", "AAAA", Base.encode64(:binary.copy("k", 17))] do
        {listener, port} = listen()
        ref = accepting(listener)
        client = raw_client(port, String.replace(@request, "AAAAAAAAAAAAAAAAAAAAAA==", key))

        assert verdict(ref) == {:error, "invalid key"}
        assert response(client) =~ ~r"^HTTP/1.1 400 "
      end
    end
  end

  describe "a server accepts" do
    test "Connection as a token list and Upgrade in any case" do
      {listener, port} = listen()
      ref = accepting(listener)

      request =
        @request
        |> String.replace("Upgrade: websocket", "Upgrade: WebSocket")
        |> String.replace("Connection: Upgrade", "Connection: keep-alive, Upgrade")

      raw_client(port, request)

      assert {:ok, %Socket.Web{key: "AAAAAAAAAAAAAAAAAAAAAA=="}} = verdict(ref)
    end

    test "a 4 KiB header line" do
      {listener, port} = listen()
      ref = accepting(listener)

      cookie = :binary.copy("c", 4_096)

      raw_client(
        port,
        String.replace(@request, "Host: x\r\n", "Host: x\r\nCookie: #{cookie}\r\n")
      )

      assert {:ok, %Socket.Web{headers: %{"cookie" => ^cookie}}} = verdict(ref)
    end
  end

  describe "a value with a CR or LF" do
    test "is refused on connect" do
      {_listener, port} = listen()

      for options <- [
            [path: "/\r\nX-Injected: 1"],
            [origin: "http://x\r\nX-Injected: 1"],
            [protocol: ["chat\r\nX-Injected: 1"]],
            [headers: %{"X-Injected" => "1\r\nX-Other: 2"}]
          ] do
        assert_raise ArgumentError, fn -> Socket.Web.connect!("localhost", port, options) end
      end
    end

    test "is refused when the server answers the handshake" do
      {listener, port} = listen()
      ref = accepting(listener)
      raw_client(port, @request)
      {:ok, client} = verdict(ref)

      assert_raise ArgumentError, fn -> Socket.Web.accept!(client, protocol: "a\r\nX: y") end
    end
  end

  describe "a client refuses" do
    test "a server that stalls inside the headers, once the timeout given to connect is up" do
      port =
        raw_server(fn sock ->
          Socket.Stream.send!(sock, "HTTP/1.1 101 Switching Protocols\r\n")
        end)

      assert Socket.Web.connect("localhost", port, timeout: 300) == {:error, "timeout"}
    end

    test "a server that answers with endless headers" do
      port =
        raw_server(fn sock ->
          Socket.Stream.send!(sock, "HTTP/1.1 101 Switching Protocols\r\n")
          for i <- 1..200, do: Socket.Stream.send!(sock, "X-#{i}: y\r\n")
        end)

      assert Socket.Web.connect("localhost", port) == {:error, "too many headers"}
    end

    test "a server that answers with garbage after the status line" do
      port =
        raw_server(fn sock ->
          Socket.Stream.send!(sock, "HTTP/1.1 101 Switching Protocols\r\n\x00\x01\x02\r\n\r\n")
        end)

      assert Socket.Web.connect("localhost", port) == {:error, "malformed handshake"}
    end

    test "a server that answers with a status other than 101" do
      port =
        raw_server(fn sock -> Socket.Stream.send!(sock, "HTTP/1.1 403 Forbidden\r\n\r\n") end)

      assert Socket.Web.connect("localhost", port) == {:error, {403, "Forbidden"}}
    end
  end

  describe "over TLS" do
    @describetag :needs_pki

    test "the handshake completes and a message goes through" do
      pki = Socket.TestPKI.paths()

      listener =
        Socket.Web.listen!(0,
          secure: true,
          cert: [path: pki.server_cert],
          key: [path: pki.server_key]
        )

      {_ip, port} = Socket.Web.local!(listener)

      Task.start_link(fn ->
        client = Socket.Web.accept!(listener, timeout: 3_000)
        client = Socket.Web.accept!(client)
        Socket.Web.send!(client, Socket.Web.recv!(client))
        Process.sleep(:infinity)
      end)

      socket =
        Socket.Web.connect!("localhost", port,
          secure: true,
          authorities: [path: pki.ca],
          verify: true,
          timeout: 3_000
        )

      Socket.Web.send!(socket, {:text, "over tls"})
      assert Socket.Web.recv!(socket, timeout: 3_000) == {:text, "over tls"}
    end
  end
end

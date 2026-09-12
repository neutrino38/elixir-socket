defmodule Socket.WebRecvTest do
  use ExUnit.Case, async: true

  import Bitwise

  # Both ends of one websocket, handshake done. The server end lives in a task
  # that stays alive: its socket would close with it.
  defp pair(options \\ []) do
    listener = Socket.Web.listen!(0, options[:listen] || [])
    {_ip, port} = Socket.Web.local!(listener)
    parent = self()

    Task.start_link(fn ->
      client = Socket.Web.accept!(listener)
      client = Socket.Web.accept!(client, options[:accept] || [])
      Kernel.send(parent, {:server, client})
      Process.sleep(:infinity)
    end)

    client = Socket.Web.connect!("localhost", port, options[:connect] || [])
    assert_receive {:server, server}, 1_000
    {client, server}
  end

  # An unmasked frame header announcing `length` bytes.
  defp header(opcode, length, fin \\ 1) do
    cond do
      length <= 125 -> <<fin::1, 0::3, opcode::4, 0::1, length::7>>
      length <= 65_535 -> <<fin::1, 0::3, opcode::4, 0::1, 126::7, length::16>>
      true -> <<fin::1, 0::3, opcode::4, 0::1, 127::7, length::64>>
    end
  end

  defp raw(%Socket.Web{socket: socket}, bytes), do: Socket.Stream.send!(socket, bytes)

  defp bytes(n), do: :binary.copy(<<7>>, n)

  describe "max_size in passive mode" do
    test "an announced length above the limit is refused before the payload is read" do
      for length <- [60_000, 1 <<< 40] do
        {client, server} = pair(connect: [max_size: 1_000])
        raw(server, header(2, length))

        assert Socket.Web.recv(client, timeout: 1_000) == {:error, :message_too_big}
        assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :message_too_big, ""}}
        assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :abnormal, nil}}
      end
    end

    test "a frame at the limit passes, one byte more does not" do
      {client, server} = pair(connect: [max_size: 5])

      raw(server, header(2, 5) <> bytes(5))
      assert Socket.Web.recv(client, timeout: 1_000) == {:ok, {:binary, bytes(5)}}

      raw(server, header(2, 6))
      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :message_too_big}
    end

    test "the limit given to recv overrides the socket's" do
      {client, server} = pair(connect: [max_size: 3])

      raw(server, header(2, 5) <> bytes(5))
      assert Socket.Web.recv(client, max_size: 10, timeout: 1_000) == {:ok, {:binary, bytes(5)}}

      raw(server, header(2, 5))
      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :message_too_big}
    end

    test "the listener's limit reaches the clients it accepts" do
      {client, server} = pair(listen: [max_size: 100])
      assert server.max_size == 100

      Socket.Web.send!(client, {:binary, bytes(200)})
      assert Socket.Web.recv(server, timeout: 1_000) == {:error, :message_too_big}
      assert Socket.Web.recv(client, timeout: 1_000) == {:ok, {:close, :message_too_big, ""}}
    end

    test "accept overrides the listener's limit" do
      {_client, server} = pair(listen: [max_size: 100], accept: [max_size: 50])
      assert server.max_size == 50
    end

    test "a limit that is not a size is rejected" do
      assert_raise ArgumentError, fn -> Socket.Web.listen!(0, max_size: "1MB") end

      {client, _server} = pair()
      assert_raise ArgumentError, fn -> Socket.Web.recv(client, max_size: -1) end
    end

    test "control frames are not subject to the limit" do
      {client, server} = pair(connect: [max_size: 0])

      raw(server, header(9, 125) <> bytes(125))
      assert Socket.Web.recv(client, timeout: 1_000) == {:ok, {:ping, bytes(125)}}
    end
  end

  describe "max_size in active mode" do
    test "a frame over the limit closes the connection with 1009" do
      {_client, server} = pair(connect: [max_size: 10, mode: :active, process: self()])

      raw(server, header(2, 11) <> bytes(11))

      assert_receive {:web_closed, %Socket.Web{}, :message_too_big}, 1_000
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :message_too_big, ""}}
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :abnormal, nil}}
    end

    test "the limit binds the whole fragmented message" do
      {_client, server} = pair(connect: [max_size: 10, mode: :active, process: self()])

      raw(server, header(2, 4, 0) <> bytes(4))
      raw(server, header(0, 4, 1) <> bytes(4))
      assert_receive {:web, %Socket.Web{}, data}, 1_000
      assert data == bytes(8)

      raw(server, header(2, 4, 0) <> bytes(4))
      raw(server, header(0, 4, 0) <> bytes(4))
      raw(server, header(0, 4, 1) <> bytes(4))

      assert_receive {:web_closed, %Socket.Web{}, :message_too_big}, 1_000
      refute_received {:web, _, _}
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :message_too_big, ""}}
    end

    test "a protocol error closes the connection with 1002" do
      {_client, server} = pair(connect: [mode: :active, process: self()])

      raw(server, header(8, 1) <> <<3>>)

      assert_receive {:web_closed, %Socket.Web{}, :protocol_error}, 1_000
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :protocol_error, ""}}
    end
  end

  describe "masking" do
    test "a server refuses an unmasked frame" do
      {client, server} = pair()

      raw(client, header(2, 3) <> "abc")

      assert Socket.Web.recv(server, timeout: 1_000) == {:error, :protocol_error}
      assert Socket.Web.recv(client, timeout: 1_000) == {:ok, {:close, :protocol_error, ""}}
    end

    test "a client refuses a masked frame" do
      {client, server} = pair()

      raw(server, <<1::1, 0::3, 2::4, 1::1, 3::7, 0::32, "abc">>)

      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :protocol_error}
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :protocol_error, ""}}
    end
  end

  describe "a close frame in active mode" do
    test "is answered with one, and the transport is closed" do
      {_client, server} = pair(connect: [mode: :active, process: self()])

      Socket.Web.close(server, :going_away, wait: false)

      assert_receive {:web_closed, %Socket.Web{}, :going_away}, 1_000
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :going_away, ""}}
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :abnormal, nil}}
    end

    test "carries an application code back" do
      {_client, server} = pair(connect: [mode: :active, process: self()])

      Socket.Web.close(server, 4000, wait: false)

      assert_receive {:web_closed, %Socket.Web{}, 4000}, 1_000
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, 4000, ""}}
    end
  end

  describe "malformed frames" do
    test "a peer that goes away inside a frame is an error, not a crash" do
      {client, server} = pair()

      raw(server, header(1, 10) <> "abc")
      Socket.Web.abort(server)

      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :closed}
    end

    test "a control frame longer than 125 bytes is a protocol error" do
      {client, server} = pair()

      raw(server, <<1::1, 0::3, 9::4, 0::1, 126::7, 200::16>>)
      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :protocol_error}
      assert Socket.Web.recv(server, timeout: 1_000) == {:ok, {:close, :protocol_error, ""}}
    end

    test "a close frame with a one-byte payload is a protocol error" do
      {client, server} = pair()

      raw(server, header(8, 1) <> <<3>>)
      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :protocol_error}
    end

    test "a 64-bit length with its top bit set is a protocol error" do
      {client, server} = pair()

      raw(server, <<1::1, 0::3, 2::4, 0::1, 127::7, 1::1, 0::63>>)
      assert Socket.Web.recv(client, timeout: 1_000) == {:error, :protocol_error}
    end
  end

  describe "send" do
    test "a 65_536-byte message round-trips" do
      {client, server} = pair()

      Socket.Web.send!(client, {:binary, bytes(65_536)})

      assert {:ok, {:binary, data}} = Socket.Web.recv(server, timeout: 2_000)
      assert byte_size(data) == 65_536
    end
  end

  describe "close" do
    test "with a timeout, a silent peer does not keep close waiting" do
      {client, _server} = pair()

      task = Task.async(fn -> Socket.Web.close(client, :normal, timeout: 200) end)

      assert {:ok, {:error, :timeout}} = Task.yield(task, 2_000) || Task.shutdown(task)
    end
  end
end

defmodule Socket.WebActiveTest do
  use ExUnit.Case, async: true

  defp listen do
    listener = Socket.Web.listen!(0)
    {_ip, port} = Socket.Web.local!(listener)
    {listener, port}
  end

  defp serve(listener, body) do
    Task.start_link(fn ->
      client = Socket.Web.accept!(listener)
      Socket.Web.accept!(client)
      body.(client)
    end)
  end

  test "a message carries the socket the caller holds" do
    {listener, port} = listen()
    serve(listener, fn client -> Socket.Web.send!(client, {:text, "hello"}) end)

    socket = Socket.Web.connect!("localhost", port, mode: :active, process: self())

    assert_receive {:web, ^socket, "hello"}, 1_000
  end

  test "turning active mode off stops the reader" do
    {listener, port} = listen()
    parent = self()

    serve(listener, fn client ->
      Kernel.send(parent, {:server, client})
      Process.sleep(5_000)
    end)

    socket = Socket.Web.connect!("localhost", port, mode: :active, process: self())
    reader = socket.active_pid
    assert Process.alive?(reader)

    socket = Socket.Web.active(socket, false)
    assert socket.active_pid == nil
    refute Process.alive?(reader)

    assert_receive {:server, client}, 1_000
    Socket.Web.send!(client, {:text, "after"})
    refute_receive {:web, _, "after"}, 300
  end
end

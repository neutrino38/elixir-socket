defmodule PortTest do
  use ExUnit.Case

  test "cat" do
    cat = Socket.Port.open!("cat")
    cat |> Socket.Stream.send!("hi!\n")
    assert cat |> Socket.Stream.recv!(timeout: 1000) == "hi!\n"
  end

  test "env" do
    env = Socket.Port.open!("env | grep FOO", env: %{"FOO" => "BAR"})
    assert env |> Socket.Stream.recv!(timeout: 1000) == "FOO=BAR\n"
  end
end

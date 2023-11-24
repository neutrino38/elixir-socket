defmodule HTTP do
  def get(uri) when is_binary(uri) or is_list(uri) do
    get(URI.parse(uri))
  end

  def get(%URI{host: host, port: port, path: path}) do
    sock = Socket.TCP.connect!(host, port, packet: :line)
    sock |> Socket.Stream.send!("GET #{path || "/"} HTTP/1.1\r\nHost: #{host}\r\n\r\n")

    [_, code, text] = Regex.run(~r"HTTP/1.1 (.*?) (.*?)\s*$", sock |> Socket.Stream.recv!())

    headers = headers([], sock) |> Enum.into(%{})

    sock |> Socket.packet!(:raw)
    body = sock |> Socket.Stream.recv!(String.to_integer(headers["Content-Length"]))

    {{String.to_integer(code), text}, headers, body}
  end

  defp headers(acc, sock) do
    case sock |> Socket.Stream.recv!() do
      "\r\n" ->
        acc

      line ->
        [_, name, value] = Regex.run(~r/^(.*?):\s*(.*?)\s*$/, line)

        headers([{name, value} | acc], sock)
    end
  end
end

defmodule HttpTest do
  use ExUnit.Case

  test "get" do
    {{200, "OK"}, headers, body} = HTTP.get("http://www.example.com")
    assert headers["Content-Type"] == "text/html; charset=UTF-8"
    assert String.contains?(body, "<html")
  end
end

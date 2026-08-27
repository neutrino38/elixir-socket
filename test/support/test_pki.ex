defmodule Socket.TestPKI do
  @moduledoc """
  A throw-away PKI for the mTLS tests: one CA, a server certificate it signed, a
  client certificate it signed, and a self-signed certificate it did not.

  Generated with `openssl` into a temporary directory on first use and cached for
  the run. Nothing is committed: key material in a repository is a liability, and
  a committed certificate expires on a date nobody is watching.

  `available?/0` is false when `openssl` is not on the PATH, and the tests that
  need real key material skip rather than fail.
  """

  @doc "Paths to the generated material, or `:unavailable`."
  @spec paths() :: map() | :unavailable
  def paths do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        result = generate()
        :persistent_term.put(__MODULE__, result)
        result

      cached ->
        cached
    end
  end

  @spec available?() :: boolean()
  def available?, do: paths() != :unavailable

  defp generate do
    with {:ok, openssl} <- find_openssl(),
         dir =
           Path.join(System.tmp_dir!(), "socket2-mtls-#{:erlang.unique_integer([:positive])}"),
         :ok <- File.mkdir_p(dir),
         :ok <- build(openssl, dir) do
      %{
        dir: dir,
        ca: Path.join(dir, "ca.pem"),
        server_cert: Path.join(dir, "server.pem"),
        server_key: Path.join(dir, "server.key"),
        client_cert: Path.join(dir, "client.pem"),
        client_key: Path.join(dir, "client.key"),
        # Signed by nobody this PKI knows: what an untrusted peer looks like.
        rogue_cert: Path.join(dir, "rogue.pem"),
        rogue_key: Path.join(dir, "rogue.key"),
        # A second CA, and a server certificate it signed. Used to show what a
        # trust store REPLACES and what it would merely add to.
        other_ca: Path.join(dir, "ca2.pem"),
        other_cert: Path.join(dir, "other.pem"),
        other_key: Path.join(dir, "other.key")
      }
    else
      _ -> :unavailable
    end
  end

  defp find_openssl do
    case System.find_executable("openssl") do
      nil -> :error
      path -> {:ok, path}
    end
  end

  # `localhost` and 127.0.0.1 both in the SAN, because a test connects by name and
  # by literal and OTP verifies the one it was given.
  @san "subjectAltName=DNS:localhost,IP:127.0.0.1"

  defp build(openssl, dir) do
    steps = [
      ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 1 -subj /CN=Socket2TestCA),
      ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca2.key -out ca2.pem -days 1 -subj /CN=Socket2OtherCA),
      ~w(req -x509 -newkey rsa:2048 -nodes -keyout rogue.key -out rogue.pem -days 1 -subj /CN=rogue),
      ~w(req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj /CN=localhost),
      ~w(req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj /CN=socket2-client),
      ~w(req -newkey rsa:2048 -nodes -keyout other.key -out other.csr -subj /CN=localhost)
    ]

    with :ok <- run_all(openssl, dir, steps),
         :ok <- File.write(Path.join(dir, "san.cnf"), @san),
         :ok <-
           run_all(openssl, dir, [
             ~w(x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem
                -days 1 -extfile san.cnf),
             ~w(x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client.pem
                -days 1),
             ~w(x509 -req -in other.csr -CA ca2.pem -CAkey ca2.key -CAcreateserial -out other.pem
                -days 1 -extfile san.cnf)
           ]) do
      :ok
    end
  end

  defp run_all(openssl, dir, steps) do
    Enum.reduce_while(steps, :ok, fn args, :ok ->
      case System.cmd(openssl, args, cd: dir, stderr_to_stdout: true) do
        {_out, 0} -> {:cont, :ok}
        {out, code} -> {:halt, {:error, {code, out}}}
      end
    end)
  end
end

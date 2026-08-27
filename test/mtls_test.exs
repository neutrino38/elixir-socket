defmodule Socket.MTLSTest do
  @moduledoc """
  Mutual TLS through `Socket.SSL` alone: a listening socket that requires a
  client certificate, and a connecting socket that trusts one named authority
  and nothing else.
  """
  use ExUnit.Case, async: false

  @moduletag :needs_pki

  setup_all do
    {:ok, pki: Socket.TestPKI.paths()}
  end

  # A server that verifies its clients against `ca`, and requires a certificate.
  defp mtls_server(pki, verify) do
    {:ok, listener} =
      Socket.SSL.listen(0,
        cert: [path: pki.server_cert],
        key: [path: pki.server_key],
        authorities: [path: pki.ca],
        verify: verify
      )

    {_ip, port} = Socket.local!(listener)
    test = self()

    # The handshake's verdict is the SERVER's to report: a client refused for
    # presenting no certificate learns about it from an alert, and what the
    # server decided is what this suite is about.
    spawn(fn ->
      result =
        with {:ok, accepted} <- Socket.SSL.transport_accept(listener, timeout: 3_000),
             {:ok, sock} <- Socket.SSL.handshake(accepted, timeout: 3_000) do
          {:ok, Socket.SSL.certificate(sock)}
        end

      send(test, {:server, result})
    end)

    {listener, port}
  end

  defp client_opts(pki, extra) do
    [
      timeout: 3_000,
      authorities: [path: pki.ca],
      verify: true
    ] ++ extra
  end

  describe "a listener that requires a client certificate" do
    test "accepts a client whose certificate the CA signed, and can read it",
         %{pki: pki} do
      {listener, port} = mtls_server(pki, :required)

      assert {:ok, client} =
               Socket.SSL.connect(
                 "localhost",
                 port,
                 client_opts(pki, cert: [path: pki.client_cert], key: [path: pki.client_key])
               )

      assert_receive {:server, {:ok, {:ok, der}}}, 3_000
      assert is_binary(der)

      # The identity the server may authorize on: the client's own subject.
      assert {:OTPCertificate, _, _, _} = :public_key.pkix_decode_cert(der, :otp)

      Socket.close(client)
      Socket.close(listener)
    end

    test "refuses a client that presents no certificate at all", %{pki: pki} do
      {listener, port} = mtls_server(pki, :required)

      # verify_peer alone would have let this through: it only REQUESTS a
      # certificate. fail_if_no_peer_cert is what makes it mandatory.
      _ = Socket.SSL.connect("localhost", port, client_opts(pki, []))

      assert_receive {:server, {:error, _}}, 3_000
      Socket.close(listener)
    end

    test "refuses a client whose certificate the CA did not sign", %{pki: pki} do
      {listener, port} = mtls_server(pki, :required)

      _ =
        Socket.SSL.connect(
          "localhost",
          port,
          client_opts(pki, cert: [path: pki.rogue_cert], key: [path: pki.rogue_key])
        )

      assert_receive {:server, {:error, _}}, 3_000
      Socket.close(listener)
    end
  end

  describe "a verifying listener is expressible at all" do
    # `verify: true` used to emit the client-only customize_hostname_check, so
    # :ssl refused the listen outright with {:option, :client_only, …}. A server
    # verifies an identity; it does not check a hostname.
    test "verify: true binds, and so does verify: :required", %{pki: pki} do
      for verify <- [true, :required] do
        assert {:ok, listener} =
                 Socket.SSL.listen(0,
                   cert: [path: pki.server_cert],
                   key: [path: pki.server_key],
                   authorities: [path: pki.ca],
                   verify: verify
                 ),
               "listen failed for verify: #{inspect(verify)}"

        Socket.close(listener)
      end
    end
  end

  describe "a named authority replaces the trust store, it does not add to it" do
    test "the server it signed is accepted", %{pki: pki} do
      {listener, port} = mtls_server(pki, true)

      assert {:ok, client} = Socket.SSL.connect("localhost", port, client_opts(pki, []))

      Socket.close(client)
      Socket.close(listener)
    end

    test "a server signed by another CA is refused, public bundle or not", %{pki: pki} do
      # The whole point. :ssl takes the UNION of cacertfile and cacerts, so
      # defaulting the public bundle next to a private CA would keep trusting
      # every public authority — and any of them can issue for this name.
      {:ok, listener} =
        Socket.SSL.listen(0,
          cert: [path: pki.other_cert],
          key: [path: pki.other_key]
        )

      {_ip, port} = Socket.local!(listener)

      spawn(fn ->
        with {:ok, a} <- Socket.SSL.transport_accept(listener, timeout: 2_000),
             do: Socket.SSL.handshake(a, timeout: 2_000)
      end)

      assert {:error, _} = Socket.SSL.connect("localhost", port, client_opts(pki, []))

      Socket.close(listener)
    end
  end
end

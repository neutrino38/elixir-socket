Code.require_file("support/test_pki.ex", __DIR__)

# The mTLS tests need real key material. Without `openssl` they are excluded
# rather than failed: the library still builds and its other tests still mean
# something on a box that has none.
unless Socket.TestPKI.available?() do
  IO.puts("openssl not found — excluding the tests tagged :needs_pki")
  ExUnit.configure(exclude: [:needs_pki])
end

# Three mTLS tests provoke a fatal alert on purpose, and :ssl logs each one on
# both ends at :notice — a page of alarming lines under a passing run. Each of
# those tests asserts the alert by name, so the log carries nothing they do not.
{:ok, _} = Application.ensure_all_started(:ssl)
:ok = :logger.set_application_level(:ssl, :error)

ExUnit.start()

Code.require_file("support/test_pki.ex", __DIR__)

# The mTLS tests need real key material. Without `openssl` they are excluded
# rather than failed: the library still builds and its other tests still mean
# something on a box that has none.
unless Socket.TestPKI.available?() do
  IO.puts("openssl not found — excluding the tests tagged :needs_pki")
  ExUnit.configure(exclude: [:needs_pki])
end

ExUnit.start()

require "test_helper"

class Provider::EpassbookTest < ActiveSupport::TestCase
  def setup
    @client = Provider::Epassbook.new(dev_id: "a1b2c3d4e5f67890")
  end

  test "initializes with dev_id and defaults" do
    assert_equal "a1b2c3d4e5f67890", @client.dev_id
    assert_equal "Android:14", @client.dev_type
    assert_equal "SM-G991B", @client.dev_model
    assert_nil @client.token_id
  end

  test "EpassbookError includes code" do
    error = Provider::Epassbook::EpassbookError.new("D0002", "No update data")
    assert_equal "D0002", error.code
    assert_equal "[D0002] No update data", error.message
  end
end

class Provider::Epassbook::CryptoTest < ActiveSupport::TestCase
  test "derive_encryption_key produces 32-char key matching Python implementation" do
    key = Provider::Epassbook::Crypto.derive_encryption_key("20260426T081500123Z", "Android:14")
    assert_equal 32, key.length
    assert_equal "M=jQATyMN6jQAW0aMvjJZHUZMuDFgExN", key
  end

  test "aes_encrypt matches Python implementation" do
    key = "M=jQATyMN6jQAW0aMvjJZHUZMuDFgExN"
    ct = Provider::Epassbook::Crypto.aes_encrypt(key, "E124845471")
    assert_equal "zxF1xAvTDOy8uNYDkl9v9g==", ct
  end

  test "aes_decrypt roundtrips with aes_encrypt" do
    key = "M=jQATyMN6jQAW0aMvjJZHUZMuDFgExN"
    ct = Provider::Epassbook::Crypto.aes_encrypt(key, "E124845471")
    pt = Provider::Epassbook::Crypto.aes_decrypt(key, ct)
    assert_equal "E124845471", pt
  end

  test "sha256_signature matches Python implementation" do
    sig = Provider::Epassbook::Crypto.sha256_signature("hello")
    assert_equal "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=", sig
  end

  test "make_sequence base64 encodes timestamp" do
    seq = Provider::Epassbook::Crypto.make_sequence("20260426T081500123Z")
    assert_equal "MjAyNjA0MjZUMDgxNTAwMTIzWg==", seq
  end
end

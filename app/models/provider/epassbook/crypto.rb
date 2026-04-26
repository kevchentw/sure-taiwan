module Provider::Epassbook::Crypto
  AES_IV = ("0" * 16).freeze
  APP_INFO = "tw.com.tdcc.epassbook:3.3.4".freeze

  module_function

  def derive_encryption_key(timestamp, dev_type)
    raw = "#{timestamp}#{APP_INFO}#{dev_type}"
    encoded = Base64.strict_encode64(raw)
    chars = encoded.chars
    n = chars.length
    sb = []

    chars.each_index do |i|
      idx = i.even? ? i - (i / 2) : (n - 1) - (i / 2)
      sb << chars[idx]
      break if sb.length == 32
    end

    key = sb.join
    key = ("*" * (32 - key.length)) + key if key.length < 32
    key
  end

  def aes_encrypt(key, plaintext)
    cipher = OpenSSL::Cipher::AES.new(256, :CBC)
    cipher.encrypt
    cipher.key = key
    cipher.iv = AES_IV
    ct = cipher.update(plaintext) + cipher.final
    Base64.strict_encode64(ct)
  end

  def aes_decrypt(key, ciphertext)
    cipher = OpenSSL::Cipher::AES.new(256, :CBC)
    cipher.decrypt
    cipher.key = key
    cipher.iv = AES_IV
    pt = cipher.update(Base64.strict_decode64(ciphertext)) + cipher.final
    pt.force_encoding("UTF-8")
  end

  def sha256_signature(data)
    digest = OpenSSL::Digest::SHA256.digest(data)
    Base64.strict_encode64(digest)
  end

  def make_sequence(timestamp)
    Base64.strict_encode64(timestamp)
  end
end

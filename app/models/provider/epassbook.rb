class Provider::Epassbook
  BASE_URL = "https://epassbooksys.tdcc.com.tw/MPSBKV2/rest/".freeze
  APP_INFO = "tw.com.tdcc.epassbook:3.3.4".freeze
  API_VER = "20250220".freeze
  DEFAULT_SERVER_TIME = "19000101000000".freeze
  CA_BUNDLE_PATH = Rails.root.join("config/credentials/tdcc_ca_bundle.pem").freeze

  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2
  MAX_RETRY_DELAY = 30

  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  class EpassbookError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super("[#{code}] #{message}")
    end
  end

  attr_reader :dev_id, :dev_type, :dev_model
  attr_accessor :token_id

  def initialize(dev_id:, dev_type: "Android:14", dev_model: "SM-G991B")
    @dev_id = dev_id
    @dev_type = dev_type
    @dev_model = dev_model
    @token_id = nil
  end

  # ── Authentication ──

  def get_initial_token
    @token_id = nil  # CM001 must be sent without an existing token
    result = request("CM001", {})
    @token_id = result["tokenID"] if result["tokenID"].present?
    result
  end

  def login(user_id:, password:, login_type: "M")
    get_initial_token

    body = {
      "apiVer" => API_VER,
      "devModel" => dev_model,
      "loginCode" => password,
      "loginType" => login_type,
      "networkType" => "WIFI",
      "userID" => user_id
    }

    result = request("AU001", body, encrypt_fields: { "userID" => user_id, "loginCode" => password })
    @token_id = result["tokenID"] if result["tokenID"].present?
    result
  end

  def logout(user_id:)
    result = request("AU002", { "userID" => user_id }, encrypt_fields: { "userID" => user_id })
    @token_id = nil
    result
  end

  def request_email_otp(user_id:)
    request("AU013", {
      "apiVer" => API_VER,
      "applyType" => "D",
      "birthday" => "",
      "userID" => user_id
    }, encrypt_fields: { "userID" => user_id })
  end

  def verify_otp(user_id:, otp:, send_type: "EMAIL")
    request("AU015", {
      "applyType" => "D",
      "birthday" => "",
      "otp" => otp,
      "sendType" => send_type,
      "userID" => user_id
    }, encrypt_fields: { "userID" => user_id, "otp" => otp })
  end

  def request_mobile_otp(user_id:)
    request("AU014", {
      "applyType" => "D",
      "birthday" => "",
      "userID" => user_id
    }, encrypt_fields: { "userID" => user_id })
  end

  def refresh_token
    result = request("AU010", {})
    @token_id = result["tokenID"] if result["tokenID"].present?
    result
  end

  # ── Stock Holdings & Trades ──

  def get_balance(last_update_time: DEFAULT_SERVER_TIME)
    request("TR001", { "lastUpdateTime" => last_update_time })
  end

  def get_trade_detail(broker_no:, broker_account:, post_date: nil, txn_ser_no: nil, update_type: nil)
    body = {
      "brokerNo"      => broker_no,
      "brokerAccount" => broker_account,
      "postDate"      => post_date.to_s,
      "txnSerNo"      => txn_ser_no.to_s
    }
    body["updateType"] = update_type if update_type.present?
    data = request_full("TR002", body)
    code = data.dig("responseHeader", "returnCode").to_s
    # D0002 = "no update data" — APK treats it as valid and reads items from body
    unless %w[0000 D0002].include?(code)
      raise EpassbookError.new(code, data.dig("responseHeader", "returnMsg") || "Unknown error")
    end
    data["responseBody"] || {}
  end

  def get_all_trade_details(broker_no:, broker_account:, max_pages: 50)
    all_items = []
    post_date = nil
    txn_ser_no = nil

    max_pages.times do
      page = get_trade_detail(
        broker_no: broker_no,
        broker_account: broker_account,
        post_date: post_date,
        txn_ser_no: txn_ser_no,
        update_type: "B"
      )

      items = page["items"] || []
      break if items.empty?

      all_items.concat(items)

      # TR002 items are arrays: [0]=postDate, [1]=txnSerNo
      last = items.last
      post_date  = last[0].presence
      txn_ser_no = last[1].presence
      break if items.length < 20
    end

    all_items
  end

  def export_trade_detail(broker_no:, broker_account:, start_date:, end_date:)
    request("TR003", {
      "brokerNo" => broker_no,
      "brokerAccount" => broker_account,
      "startDate" => start_date,
      "endDate" => end_date
    })
  end

  # ── Fund ──

  def get_personal_fund_info(last_update_time: DEFAULT_SERVER_TIME)
    request("TR051V1", { "lastUpdateTime" => last_update_time })
  end

  def get_personal_fund_detail(sale_org_code:, sale_org_code_short: "", start_date:, end_date:)
    request("TR052", {
      "saleOrgCode" => sale_org_code,
      "saleOrgCodeShort" => sale_org_code_short,
      "sDate" => start_date,
      "eDate" => end_date
    })
  end

  # ── Bank / Open Banking (TSP) ──

  def get_tsp_bank_list
    request("tsp/TSP001V1", {})
  end

  def get_tsp_enable_token_list
    request("tsp/TSP005", {})
  end

  def get_tsp_balance
    request("tsp/TSP006", {})
  end

  def get_tsp_trade_detail(bank_id:, account_no:, currency:, limits_in_page: 100, page_token: "")
    request("tsp/TSP007", {
      "bankId" => bank_id,
      "accountNo" => account_no,
      "currency" => currency,
      "limitsInPage" => limits_in_page,
      "pageToken" => page_token
    })
  end

  def get_tsp_trade_detail_all(bank_id:, account_no:, currency:, limits_in_page: 100, max_pages: 20)
    all_details = []
    page_token = ""
    seen_tokens = Set.new

    max_pages.times do |i|
      page = get_tsp_trade_detail(
        bank_id: bank_id,
        account_no: account_no,
        currency: currency,
        limits_in_page: limits_in_page,
        page_token: page_token
      )

      all_details.concat(page["transactionDetails"] || [])

      return { "transactionDetails" => all_details, "fetchedPages" => i + 1, "isComplete" => true } if page["isComplete"] == true

      next_token = extract_next_page_token(page)
      break if next_token.blank? || seen_tokens.include?(next_token)

      seen_tokens.add(next_token)
      page_token = next_token
    end

    { "transactionDetails" => all_details, "fetchedPages" => all_details.any? ? 1 : 0, "isComplete" => false }
  end

  def get_all_connected_tsp_transactions(limits_in_page: 100, max_pages: 20)
    tsp_balance = get_tsp_balance
    results = []

    (tsp_balance["tspAccountInfos"] || []).each do |bank_info|
      bank_id = bank_info["bankId"].to_s

      (bank_info["tspAccount"] || []).each do |account|
        next unless account["isShow"]

        account_no = account["accountNo"].to_s
        currency = account["currency"].to_s
        next if bank_id.blank? || account_no.blank? || currency.blank?

        item = {
          "bankId" => bank_id,
          "accountNo" => account_no,
          "currency" => currency,
          "accountType" => account["accountType"],
          "balanceAmt" => account["balanceAmt"],
          "availableBalance" => account["availableBalance"]
        }

        begin
          detail = get_tsp_trade_detail_all(
            bank_id: bank_id,
            account_no: account_no,
            currency: currency,
            limits_in_page: limits_in_page,
            max_pages: max_pages
          )
          item["tradeDetail"] = detail
          item["transactionCount"] = (detail["transactionDetails"] || []).length
        rescue EpassbookError => e
          item["error"] = { "code" => e.code, "message" => e.message }
          item["transactionCount"] = 0
        end

        results << item
      end
    end

    { "accounts" => results, "accountCount" => results.length }
  end

  # ── Credit Card (TSP) — APIs exist but not yet live ──

  def get_tsp_credit_bank_list
    request("tsp/TSP100", {})
  end

  def get_tsp_credit_limit(bank_id:)
    request("tsp/TSP101", { "bankId" => bank_id })
  end

  def get_tsp_credit_bills(bank_id:, card_no:)
    request("tsp/TSP102", { "bankId" => bank_id, "cardNo" => card_no })
  end

  def get_tsp_credit_purchases_recorded(bank_id:, card_no:, bill_date:, page_token: "")
    request("tsp/TSP103", {
      "bankId" => bank_id,
      "cardNo" => card_no,
      "billDate" => bill_date,
      "pageToken" => page_token
    })
  end

  def get_tsp_credit_purchases_not_recorded(bank_id:, card_no:, start_date:, end_date:, page_token: "")
    request("tsp/TSP104", {
      "bankId" => bank_id,
      "cardNo" => card_no,
      "startDate" => start_date,
      "endDate" => end_date,
      "pageToken" => page_token
    })
  end

  # ── Stock Info ──

  def get_deposit_info
    request("SD020", {})
  end

  def get_cash_dividend_list(start_date: nil, end_date: nil)
    body = {}
    body["notcDateStart"] = start_date if start_date.present?
    body["notcDateEnd"] = end_date if end_date.present?
    request("SD041", body)
  end

  def get_stock_dividend_list(start_date: nil, end_date: nil)
    body = {}
    body["notcDateStart"] = start_date if start_date.present?
    body["notcDateEnd"] = end_date if end_date.present?
    request("SD043", body)
  end

  # ── Asset Trend ──

  def get_asset_trend(rich_url:, type: "1Y")
    qs = rich_url.include?("?") ? rich_url[rich_url.index("?")..] : ""
    url = "https://epassbooksys.tdcc.com.tw/MPSBKV2/rest/TR087#{qs}&type=#{type}"

    uri = URI.parse(url)
    http = build_http(uri)
    req = Net::HTTP::Get.new(uri)
    req["Referer"] = "https://digitalprocesssys-epassbook.cdn.hinet.net/"
    req["User-Agent"] = "okhttp/4.9.3"

    response = with_retries("GET TR087") { http.request(req) }
    data = JSON.parse(response.body)
    data["responseBody"] || {}
  end

  private

  def request(api_code, body, encrypt_fields: nil)
    data = request_full(api_code, body, encrypt_fields: encrypt_fields)
    rs_header = data["responseHeader"] || {}
    code = rs_header["returnCode"].to_s

    unless code == "0000"
      raise EpassbookError.new(code, rs_header["returnMsg"] || "Unknown error")
    end

    data["responseBody"] || {}
  end

  def request_full(api_code, body, encrypt_fields: nil)
    timestamp = generate_timestamp
    enc_key = Crypto.derive_encryption_key(timestamp, dev_type)

    if encrypt_fields.present?
      encrypt_fields.each do |field, value|
        body[field] = Crypto.aes_encrypt(enc_key, value)
      end
    end

    body_json = body.to_json
    header = build_header(timestamp, body.present? ? body_json : nil)

    url = build_url(api_code)
    payload = { "requestHeader" => header, "requestBody" => body }.to_json

    uri = URI.parse(url)
    http = build_http(uri)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json; charset=utf-8"
    req["User-Agent"] = "okhttp/4.9.3"
    req["Connection"] = "Keep-Alive"
    req["Accept-Encoding"] = "gzip"
    req.body = payload

    response = with_retries("POST #{api_code}") { http.request(req) }
    JSON.parse(response.body)
  end

  def generate_timestamp
    now = Time.now.utc
    now.strftime("%Y%m%dT%H%M%S") + format("%03dZ", now.usec / 1000)
  end

  def build_header(timestamp, body_json = nil)
    sign_input = body_json || timestamp
    {
      "appInfo" => APP_INFO,
      "devID" => dev_id,
      "devType" => dev_type,
      "sequence" => Crypto.make_sequence(timestamp),
      "signature" => Crypto.sha256_signature(sign_input),
      "tokenID" => token_id
    }
  end

  def build_url(api_path)
    return api_path if api_path.start_with?("http://", "https://")
    "#{BASE_URL}#{api_path}"
  end

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 30

    if CA_BUNDLE_PATH.exist?
      http.ca_file = CA_BUNDLE_PATH.to_s
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end

    http
  end

  def extract_next_page_token(payload)
    case payload
    when Hash
      direct = payload["nextPageToken"] || payload["pageToken"]
      return direct.strip if direct.is_a?(String) && direct.strip.present?

      payload.each_value do |v|
        token = extract_next_page_token(v)
        return token if token.present?
      end
    when Array
      payload.each do |item|
        token = extract_next_page_token(item)
        return token if token.present?
      end
    end

    nil
  end

  def with_retries(operation_name, max_retries: MAX_RETRIES)
    retries = 0

    begin
      yield
    rescue *RETRYABLE_ERRORS => e
      retries += 1
      if retries <= max_retries
        delay = calculate_retry_delay(retries)
        Rails.logger.warn("ePassbook API: #{operation_name} failed (attempt #{retries}/#{max_retries}): #{e.class}: #{e.message}. Retrying in #{delay}s...")
        sleep(delay)
        retry
      else
        Rails.logger.error("ePassbook API: #{operation_name} failed after #{max_retries} retries: #{e.class}: #{e.message}")
        raise EpassbookError.new("NETWORK_ERROR", "Network error after #{max_retries} retries: #{e.message}")
      end
    end
  end

  def calculate_retry_delay(retry_count)
    base_delay = INITIAL_RETRY_DELAY * (2 ** (retry_count - 1))
    jitter = base_delay * rand * 0.25
    [ base_delay + jitter, MAX_RETRY_DELAY ].min
  end
end

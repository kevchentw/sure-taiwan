class EpassbookAccount::Processor
  SOURCE = "epassbook".freeze

  # ePassbook stockExcg → Yahoo Finance ticker suffix
  EXCHANGE_SUFFIX = {
    "TWSE" => ".TW",
    "OTC"  => ".TWO",
    "TPEx" => ".TWO"
  }.freeze
  DEFAULT_SUFFIX = ".TW".freeze

  # ePassbook stockExcg → ISO 10383 MIC code
  EXCHANGE_MIC = {
    "TWSE" => "XTAI",
    "OTC"  => "ROCO",
    "TPEx" => "ROCO"
  }.freeze
  DEFAULT_MIC = "XTAI".freeze

  attr_reader :epassbook_account

  def initialize(epassbook_account)
    @epassbook_account = epassbook_account
  end

  def process
    account = epassbook_account.current_account
    unless account
      Rails.logger.info("EpassbookAccount::Processor #{epassbook_account.id} - no linked account, skipping")
      return
    end

    epassbook_account.ensure_account_provider!

    if epassbook_account.stock?
      process_stock_account(account)
    elsif epassbook_account.bank?
      process_bank_account(account)
    elsif epassbook_account.fund?
      process_fund_account(account)
    end
  end

  private

    # ── Stock (TR001 holdings + TR002 trades) ──

    def process_stock_account(account)
      process_stock_holdings(account)
      process_stock_trades(account)

      total = epassbook_account.current_balance || 0
      account.assign_attributes(balance: total, currency: "TWD")
      account.save!
      account.set_current_balance(total)
    end

    def process_stock_holdings(account)
      payload     = epassbook_account.raw_payload || {}
      # TR001 items are arrays: [0]=stockNo, [1]=stockName, [7]=qty, [17]=price, [19]=currency
      stock_items = payload["items"] || []
      date        = Date.current
      ap          = epassbook_account.account_provider

      Rails.logger.info("EpassbookAccount::Processor #{epassbook_account.id} - #{stock_items.length} stock items in payload")

      stock_items.each do |item|
        stock_no   = item[0].to_s.strip
        stock_name = item[1].to_s.strip
        qty        = item[7].to_d
        price      = item[17].to_s.delete(",").to_d

        next if stock_no.blank? || qty.zero?

        security = resolve_security(stock_no, stock_name, nil)
        next unless security

        holding = account.holdings.find_or_initialize_by(
          security: security,
          date: date,
          currency: "TWD"
        )
        holding.assign_attributes(
          qty: qty,
          price: price,
          amount: (qty * price).round(2),
          account_provider: ap
        )
        holding.save!
      rescue StandardError => e
        Rails.logger.error("EpassbookAccount::Processor - holding #{item[0]} failed: #{e.message}")
      end
    end

    def process_stock_trades(account)
      payload = epassbook_account.raw_transactions_payload || {}
      trades  = payload["trades"] || []

      trades.each { |t| process_single_trade(account, t) }
    end

    def process_single_trade(account, trade)
      # TR002 items are arrays — field positions from TR002_FIELDS:
      # [0]=postDate (ROC 0RYYMMDD), [1]=txnSerNo, [2]=stockNo, [3]=stockName, [4]=stockExcg,
      # [11]=txnName, [12]=txnSHR, [14]=dbCRCode, [18]=price
      post_date  = trade[0].to_s
      txn_ser_no = trade[1].to_s
      stock_no   = trade[2].to_s.strip
      stock_name = trade[3].to_s.strip
      exchange   = trade[4].to_s.strip
      txn_name   = trade[11].to_s
      shares     = trade[12].to_d
      db_cr      = trade[14].to_s
      # ePassbook does not reliably provide trade prices (field [18] often
      # returns "1" as a placeholder). Always import with price = 0 so users
      # can fill in the correct value via the "Estimate from closing price" button.
      price      = 0

      return if stock_no.blank? || shares.zero?

      external_id = "epassbook_trade_#{post_date}_#{txn_ser_no}"
      return if account.entries.exists?(external_id: external_id)

      # TR002 postDate is ROC calendar format 0RYYMMDD (e.g. "01140917" = ROC 114-09-17 = 2025-09-17)
      date = parse_roc_date(post_date)
      return unless date

      security = resolve_security(stock_no, stock_name, exchange)
      return unless security

      # Prefer txnName keywords over dbCRCode — some ePassbook records have
      # mismatched dbCRCode (e.g. "D" for a sell recorded as "賣出").
      is_buy = if txn_name.match?(/賣|售/)
        false
      elsif txn_name.match?(/買|購/)
        true
      else
        db_cr != "C"
      end
      qty          = is_buy ? shares : -shares
      gross        = (price * shares).round(2)
      entry_amount = is_buy ? -gross : gross
      label        = is_buy ? "Buy" : "Sell"
      entry_name   = "#{txn_name.presence || label} #{stock_name} #{shares.to_i}股"

      account.entries.create!(
        date:        date,
        name:        entry_name,
        amount:      entry_amount,
        currency:    "TWD",
        external_id: external_id,
        source:      SOURCE,
        entryable:   Trade.new(
          security:                  security,
          qty:                       qty,
          price:                     price,
          currency:                  "TWD",
          fee:                       0,
          investment_activity_label: label
        )
      )
    rescue StandardError => e
      Rails.logger.error("EpassbookAccount::Processor - trade #{trade[0]}:#{trade[1]} failed: #{e.message}")
    end

    # ── Fund (TR051V1 holdings + TR052 trades) ──

    def process_fund_account(account)
      payload      = epassbook_account.raw_payload || {}
      fund_details = payload["fundDetails"] || []
      date         = Date.current
      ap           = epassbook_account.account_provider

      fund_details.each do |fund|
        fund_no   = fund["fundNo"].to_s.strip
        fund_name = fund["fundCHName"].to_s.strip
        qty       = fund["fundSHR"].to_s.delete(",").to_d
        price     = fund["navValue"].to_s.delete(",").to_d
        currency  = fund["currAlias"].presence || "TWD"

        next if fund_no.blank? || qty.zero?

        security = resolve_fund_security(fund_no, fund_name)
        next unless security

        holding = account.holdings.find_or_initialize_by(
          security: security,
          date: date,
          currency: currency
        )
        holding.assign_attributes(
          qty: qty,
          price: price,
          amount: (qty * price).round(2),
          account_provider: ap
        )
        holding.save!
      rescue StandardError => e
        Rails.logger.error("EpassbookAccount::Processor - fund holding #{fund_no} failed: #{e.message}")
      end

      process_fund_trades(account)

      total = epassbook_account.current_balance || 0
      account.assign_attributes(balance: total, currency: "TWD")
      account.save!
      account.set_current_balance(total)
    end

    def process_fund_trades(account)
      payload = epassbook_account.raw_transactions_payload || {}
      items   = payload["fund_trades"] || []

      items.each { |item| process_single_fund_trade(account, item) }
    end

    def process_single_fund_trade(account, item)
      fund_no        = item["fundNo"].to_s.strip
      fund_name      = item["fundName"].to_s.strip
      area           = item["area"].to_s.strip
      unit_str       = item["unit"].to_s.strip
      net_value_date = item["netValueDate"].to_s.strip

      return if fund_no.blank?

      # content[] and details[] are [{key, value}] pairs from the server
      kv = {}
      (item["content"] || []).each { |p| kv[p["key"].to_s] = p["value"].to_s }
      (item["details"] || []).each { |p| kv[p["key"].to_s] = p["value"].to_s }

      units = unit_str.delete(",").to_d
      return if units.zero?

      # Determine trade date — try common Chinese key names, fall back to netValueDate + current year
      date = extract_fund_trade_date(kv, net_value_date)
      return unless date

      external_id = "epassbook_fund_trade_#{fund_no}_#{area}_#{unit_str}_#{net_value_date}"
      return if account.entries.exists?(external_id: external_id)

      security = resolve_fund_security(fund_no, fund_name)
      return unless security

      # area or key-value content determines buy/sell; positive units = buy, negative = sell
      is_buy = !area.include?("贖回") && units.positive?
      qty    = is_buy ? units.abs : -units.abs
      label  = is_buy ? "Buy" : "Sell"

      # Amount: try to find from content/details, otherwise use units × NAV
      nav   = (kv["淨值"] || kv["申購淨值"] || kv["贖回淨值"] || kv["成交淨值"] || "0").delete(",").to_d
      gross = if nav.positive?
        (units.abs * nav).round(2)
      else
        units.abs
      end
      entry_amount = is_buy ? -gross : gross

      txn_type_label = kv["交易類型"] || kv["申購/贖回別"] || area.presence || label
      entry_name     = "#{txn_type_label} #{fund_name} #{units.abs}單位"

      account.entries.create!(
        date:        date,
        name:        entry_name,
        amount:      entry_amount,
        currency:    "TWD",
        external_id: external_id,
        source:      SOURCE,
        entryable:   Trade.new(
          security:                  security,
          qty:                       qty,
          price:                     nav.positive? ? nav : 0,
          currency:                  "TWD",
          fee:                       0,
          investment_activity_label: label
        )
      )
    rescue StandardError => e
      Rails.logger.error("EpassbookAccount::Processor - fund trade #{item["fundNo"]}:#{item["area"]} failed: #{e.message}")
    end

    def extract_fund_trade_date(kv, net_value_date)
      # Try known Chinese key names: Gregorian YYYYMMDD, ROC 0RYYMMDD, or ROC YYY/MM/DD
      date_str = kv["交易日期"] || kv["申購日期"] || kv["贖回日期"] || kv["成交日期"] ||
                 kv["申購淨值日"] || kv["贖回淨值日"] || kv["基準日"]

      if date_str.present?
        return parse_yyyymmdd(date_str) ||
               parse_roc_date(date_str) ||
               parse_roc_slash_date(date_str)
      end

      # netValueDate may be YYYY/MM/DD (Gregorian), MMDD, or blank
      return nil if net_value_date.blank?

      # Gregorian YYYY/MM/DD or YYYY-MM-DD (10 chars)
      if net_value_date.length == 10
        return Date.parse(net_value_date)
      end

      # MMDD fallback (4 chars)
      return nil unless net_value_date.length == 4

      month = net_value_date[0, 2].to_i
      day   = net_value_date[2, 2].to_i
      year  = Date.current.year
      candidate = Date.new(year, month, day)
      candidate > Date.current ? Date.new(year - 1, month, day) : candidate
    rescue Date::Error, ArgumentError
      nil
    end

    # ROC date in YYY/MM/DD or YYY-MM-DD format (e.g. "115/03/30" = 2026-03-30)
    def parse_roc_slash_date(str)
      return nil if str.blank?
      parts = str.split(%r{[/\-]})
      return nil unless parts.length == 3
      roc_year = parts[0].to_i
      return nil if roc_year <= 0
      Date.new(roc_year + 1911, parts[1].to_i, parts[2].to_i)
    rescue Date::Error, ArgumentError
      nil
    end

    # ── Bank (TSP007 transactions) ──

    def process_bank_account(account)
      account.update!(
        balance:  epassbook_account.current_balance || 0,
        currency: epassbook_account.currency || "TWD"
      )

      payload = epassbook_account.raw_transactions_payload || {}
      (payload["transactions"] || []).each { |t| process_single_bank_txn(account, t) }
    end

    def process_single_bank_txn(account, txn)
      txn_dt    = txn["txnDateTime"].to_s  # "2026-04-01T10:30:00"
      summary   = txn["summary"].to_s
      in_amt    = txn["transferInAmount"].to_s.delete(",").to_d
      out_amt   = txn["transferOutAmount"].to_s.delete(",").to_d
      memo      = txn["memo"].to_s

      return if in_amt.zero? && out_amt.zero?

      external_id = "epassbook_bank_#{epassbook_account.remote_id}_#{txn_dt}_#{in_amt}_#{out_amt}"
      return if account.entries.exists?(external_id: external_id)

      date = Date.parse(txn_dt[0, 10])
      amount = out_amt.nonzero? ? out_amt : -in_amt
      name   = summary.presence || memo.presence || (amount.positive? ? "提出" : "存入")

      account.entries.create!(
        date:        date,
        name:        name,
        amount:      amount,
        currency:    epassbook_account.currency || "TWD",
        external_id: external_id,
        source:      SOURCE,
        entryable:   Transaction.new
      )
    rescue ArgumentError, Date::Error => e
      Rails.logger.warn("EpassbookAccount::Processor - could not parse bank txn date #{txn_dt}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("EpassbookAccount::Processor - bank txn #{txn_dt} failed: #{e.message}")
    end

    # ── Helpers ──

    def resolve_security(stock_no, stock_name, exchange)
      suffix = EXCHANGE_SUFFIX.fetch(exchange, DEFAULT_SUFFIX)
      mic    = EXCHANGE_MIC.fetch(exchange, DEFAULT_MIC)
      ticker = "#{stock_no}#{suffix}"

      Security.find_or_create_by!(ticker: ticker) do |s|
        s.name                   = stock_name.presence || stock_no
        s.exchange_operating_mic = mic
        s.country_code           = "TW"
      end
    rescue StandardError => e
      Rails.logger.warn("EpassbookAccount::Processor - could not resolve security #{stock_no}: #{e.message}")
      nil
    end

    def resolve_fund_security(fund_no, fund_name)
      Security.find_or_create_by!(ticker: fund_no) do |s|
        s.name                   = fund_name.presence || fund_no
        s.exchange_operating_mic = DEFAULT_MIC
        s.country_code           = "TW"
      end
    rescue StandardError => e
      Rails.logger.warn("EpassbookAccount::Processor - could not resolve fund #{fund_no}: #{e.message}")
      nil
    end

    def parse_yyyymmdd(str)
      return nil if str.blank? || str.length < 8
      Date.strptime(str[0, 8], "%Y%m%d")
    rescue Date::Error
      nil
    end

    # TR002 postDate is ROC calendar in format 0RYYMMDD
    # e.g. "01140917" → ROC year 114, month 09, day 17 → Gregorian 2025-09-17
    def parse_roc_date(str)
      return nil if str.blank? || str.length != 8

      roc_year = str[1, 3].to_i
      month    = str[4, 2].to_i
      day      = str[6, 2].to_i
      Date.new(roc_year + 1911, month, day)
    rescue Date::Error, ArgumentError
      nil
    end
end

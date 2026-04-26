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
      # [0]=postDate, [1]=txnSerNo, [2]=stockNo, [3]=stockName, [4]=stockExcg,
      # [11]=txnName, [12]=txnSHR, [14]=dbCRCode, [18]=price
      post_date  = trade[0].to_s
      txn_ser_no = trade[1].to_s
      stock_no   = trade[2].to_s.strip
      stock_name = trade[3].to_s.strip
      exchange   = trade[4].to_s.strip
      txn_name   = trade[11].to_s
      shares     = trade[12].to_d
      db_cr      = trade[14].to_s
      price      = trade[18].to_s.delete(",").to_d

      return if stock_no.blank? || shares.zero?

      external_id = "epassbook_trade_#{post_date}_#{txn_ser_no}"
      return if account.entries.exists?(external_id: external_id)

      date = parse_yyyymmdd(post_date)
      return unless date

      security = resolve_security(stock_no, stock_name, exchange)
      return unless security

      is_buy       = db_cr != "C"
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

    # ── Fund (TR051V1 holdings) ──

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

      total = epassbook_account.current_balance || 0
      account.assign_attributes(balance: total, currency: "TWD")
      account.save!
      account.set_current_balance(total)
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
      amount = in_amt.nonzero? ? in_amt : -out_amt
      name   = summary.presence || memo.presence || (amount.positive? ? "存入" : "提出")

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
      Date.strptime(str, "%Y%m%d")
    rescue Date::Error
      nil
    end
end

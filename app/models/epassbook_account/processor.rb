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
    end
  end

  private

    # ── Stock (TR001 holdings + TR002 trades) ──

    def process_stock_account(account)
      process_stock_holdings(account)
      process_stock_trades(account)
    end

    def process_stock_holdings(account)
      payload     = epassbook_account.raw_payload || {}
      stock_items = payload["items"] || []
      date        = Date.current
      ap          = epassbook_account.account_provider

      stock_items.each do |item|
        stock_no   = item["stockNo"].to_s.strip
        stock_name = item["stockName"].to_s.strip
        exchange   = item["stockExcg"].to_s.strip
        qty        = item["stockUnit"].to_d
        price      = item["stockPrice"].to_s.delete(",").to_d

        next if stock_no.blank? || qty.zero?

        security = resolve_security(stock_no, stock_name, exchange)
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
        Rails.logger.error("EpassbookAccount::Processor - holding #{item["stockNo"]} failed: #{e.message}")
      end
    end

    def process_stock_trades(account)
      payload = epassbook_account.raw_transactions_payload || {}
      trades  = payload["trades"] || []

      trades.each { |t| process_single_trade(account, t) }
    end

    def process_single_trade(account, trade)
      post_date  = trade["postDate"].to_s   # "20260401"
      txn_ser_no = trade["txnSerNo"].to_s
      stock_no   = trade["stockNo"].to_s.strip
      stock_name = trade["stockName"].to_s.strip
      exchange   = trade["stockExcg"].to_s.strip
      txn_name   = trade["txnName"].to_s
      shares     = trade["txnSHR"].to_d
      price      = trade["price"].to_s.delete(",").to_d
      db_cr      = trade["dbCRCode"].to_s  # "D"=debit/buy, "C"=credit/sell

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
      Rails.logger.error("EpassbookAccount::Processor - trade #{trade["postDate"]}:#{trade["txnSerNo"]} failed: #{e.message}")
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
        s.currency               = "TWD"
      end
    rescue StandardError => e
      Rails.logger.warn("EpassbookAccount::Processor - could not resolve security #{stock_no}: #{e.message}")
      nil
    end

    def parse_yyyymmdd(str)
      return nil if str.blank? || str.length < 8
      Date.strptime(str, "%Y%m%d")
    rescue Date::Error
      nil
    end
end

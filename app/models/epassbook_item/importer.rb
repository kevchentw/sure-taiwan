class EpassbookItem::Importer
  attr_reader :epassbook_item, :client

  def initialize(epassbook_item, epassbook_client:)
    @epassbook_item = epassbook_item
    @client = epassbook_client
  end

  def import(sync: nil)
    Rails.logger.info("EpassbookItem::Importer #{epassbook_item.id} - starting import")

    login!

    stats = { stock_accounts: 0, bank_accounts: 0, errors: [] }

    import_stock_accounts(stats)
    import_bank_accounts(stats)

    epassbook_item.save_token!(client.token_id)

    Rails.logger.info("EpassbookItem::Importer #{epassbook_item.id} - done: #{stats.inspect}")
    stats
  rescue Provider::Epassbook::EpassbookError => e
    handle_auth_error(e)
    raise
  end

  private

    def login!
      result = client.login(
        user_id: epassbook_item.tdcc_user_id,
        password: epassbook_item.tdcc_password
      )
      epassbook_item.save_token!(client.token_id)

      if result["isDiffDevice"] == "Y"
        raise Provider::Epassbook::EpassbookError.new("DIFF_DEVICE",
          "New device detected — OTP verification required before syncing")
      end
    end

    # ── Stock accounts (TR001 holdings + TR002 trades) ──

    def import_stock_accounts(stats)
      last_update_time = epassbook_item.last_stock_update_time.presence || Provider::Epassbook::DEFAULT_SERVER_TIME
      balance_result = client.get_balance(last_update_time: last_update_time)

      epassbook_item.upsert_raw_snapshot!(balance_result)

      broker_items = balance_result["items"] || []
      new_server_time = balance_result["serverTime"]

      broker_items.each do |broker|
        broker_no      = broker["brokerNo"].to_s
        broker_account = broker["brokerAccount"].to_s
        broker_name    = broker["brokerName"].to_s
        remote_id      = "#{broker_no}:#{broker_account}"

        ea = epassbook_item.epassbook_accounts.find_or_initialize_by(
          account_subtype: "stock",
          remote_id: remote_id
        )

        is_new = ea.new_record?

        ea.assign_attributes(
          name: broker_name.presence || "證券帳戶 #{broker_account}",
          broker_no: broker_no,
          broker_account: broker_account,
          broker_name: broker_name,
          currency: "TWD",
          raw_payload: broker
        )
        ea.save!

        import_stock_trades(ea)
        stats[:stock_accounts] += 1
      rescue StandardError => e
        Rails.logger.error("EpassbookItem::Importer - stock #{remote_id} failed: #{e.message}")
        stats[:errors] << { type: "stock", remote_id: remote_id, message: e.message }
      end

      epassbook_item.update!(last_stock_update_time: new_server_time) if new_server_time.present?
    end

    def import_stock_trades(epassbook_account)
      trades = client.get_all_trade_details(
        broker_no: epassbook_account.broker_no,
        broker_account: epassbook_account.broker_account
      )

      return if trades.empty?

      existing = epassbook_account.raw_transactions_payload&.dig("trades") || []
      seen = existing.map { |t| "#{t["postDate"]}:#{t["txnSerNo"]}" }.to_set
      new_trades = trades.reject { |t| seen.include?("#{t["postDate"]}:#{t["txnSerNo"]}") }

      return if new_trades.empty?

      merged = existing + new_trades
      epassbook_account.upsert_transactions_snapshot!({
        "trades" => merged,
        "fetched_at" => Time.current.iso8601
      })

      last = new_trades.last
      epassbook_account.update!(
        last_txn_post_date: last["postDate"].to_s,
        last_txn_ser_no: last["txnSerNo"].to_s
      )
    end

    # ── Bank accounts (TSP006 balance + TSP007 transactions) ──

    def import_bank_accounts(stats)
      tsp_balance = client.get_tsp_balance
      bank_infos  = tsp_balance["tspAccountInfos"] || []

      bank_infos.each do |bank_info|
        bank_id = bank_info["bankId"].to_s

        (bank_info["tspAccount"] || []).each do |acct|
          next unless acct["isShow"]

          account_no = acct["accountNo"].to_s
          currency   = acct["currency"].to_s
          remote_id  = "#{bank_id}:#{account_no}:#{currency}"

          ea = epassbook_item.epassbook_accounts.find_or_initialize_by(
            account_subtype: "bank",
            remote_id: remote_id
          )

          balance_amt = acct["balanceAmt"].to_s.delete(",").to_d

          ea.assign_attributes(
            name: "銀行帳戶 #{account_no.last(4)}",
            bank_id: bank_id,
            account_no: account_no,
            currency: currency,
            current_balance: balance_amt,
            raw_payload: acct
          )
          ea.save!

          import_bank_transactions(ea)
          stats[:bank_accounts] += 1
        rescue StandardError => e
          Rails.logger.error("EpassbookItem::Importer - bank #{remote_id} failed: #{e.message}")
          stats[:errors] << { type: "bank", remote_id: remote_id, message: e.message }
        end
      end
    end

    def import_bank_transactions(epassbook_account)
      result = client.get_tsp_trade_detail_all(
        bank_id: epassbook_account.bank_id,
        account_no: epassbook_account.account_no,
        currency: epassbook_account.currency
      )

      details = result["transactionDetails"] || []
      return if details.empty?

      existing = epassbook_account.raw_transactions_payload&.dig("transactions") || []
      seen = existing.map { |t| "#{t["txnDateTime"]}:#{t["transferInAmount"]}:#{t["transferOutAmount"]}" }.to_set
      new_txns = details.reject { |t| seen.include?("#{t["txnDateTime"]}:#{t["transferInAmount"]}:#{t["transferOutAmount"]}") }

      return if new_txns.empty?

      epassbook_account.upsert_transactions_snapshot!({
        "transactions" => existing + new_txns,
        "fetched_at" => Time.current.iso8601,
        "isComplete" => result["isComplete"]
      })
    end

    def handle_auth_error(error)
      auth_error_codes = %w[AU0001 AU0002 AU0003 AU0004 SESSION_EXPIRED INVALID_TOKEN]
      epassbook_item.update!(status: :requires_update) if auth_error_codes.include?(error.code)
    end
end

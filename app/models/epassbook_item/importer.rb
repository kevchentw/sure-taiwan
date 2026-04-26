class EpassbookItem::Importer
  TW_BANK_NAMES = {
    "000" => "中央銀行國庫局",
    "004" => "臺灣銀行",
    "005" => "臺灣土地銀行",
    "006" => "合作金庫商業銀行",
    "007" => "第一商業銀行",
    "008" => "華南商業銀行",
    "009" => "彰化商業銀行",
    "011" => "上海商業儲蓄銀行",
    "012" => "台北富邦商業銀行",
    "013" => "國泰世華商業銀行",
    "016" => "高雄銀行",
    "017" => "兆豐國際商業銀行",
    "018" => "全國農業金庫",
    "020" => "日商瑞穗銀行台北分行",
    "021" => "花旗(台灣)商業銀行",
    "022" => "美國銀行台北分行",
    "023" => "泰國盤谷銀行台北分行",
    "025" => "菲律賓首都銀行台北分行",
    "029" => "新加坡商大華銀行台北分行",
    "030" => "美商道富銀行台北分行",
    "037" => "法商法國興業銀行台北分行",
    "039" => "澳商澳盛銀行台北分行",
    "048" => "王道商業銀行",
    "050" => "臺灣中小企業銀行",
    "052" => "渣打國際商業銀行",
    "053" => "台中商業銀行",
    "054" => "京城商業銀行",
    "060" => "兆豐票券金融",
    "061" => "中華票券金融",
    "062" => "國際票券金融",
    "066" => "萬通票券金融",
    "072" => "德商德意志銀行台北分行",
    "075" => "香港商東亞銀行台北分行",
    "076" => "美商摩根大通銀行台北分行",
    "081" => "匯豐(台灣)商業銀行",
    "082" => "法國巴黎銀行台北分行",
    "085" => "新加坡商新加坡華僑銀行台北分行",
    "086" => "法商東方匯理銀行台北分行",
    "092" => "瑞士商瑞士銀行台北分行",
    "093" => "荷商安智銀行台北分行",
    "098" => "日商三菱日聯銀行台北分行",
    "101" => "瑞興商業銀行",
    "102" => "華泰商業銀行",
    "103" => "臺灣新光商業銀行",
    "108" => "陽信商業銀行",
    "114" => "基隆第一信用合作社",
    "115" => "基隆市第二信用合作社",
    "118" => "板信商業銀行",
    "119" => "淡水第一信用合作社",
    "130" => "新竹第一信用合作社",
    "132" => "新竹第三信用合作社",
    "146" => "台中市第二信用合作社",
    "147" => "三信商業銀行",
    "162" => "彰化第六信用合作社",
    "204" => "高雄市第三信用合作社",
    "215" => "花蓮第一信用合作社",
    "216" => "花蓮第二信用合作社",
    "321" => "日商三井住友銀行台北分行",
    "326" => "西班牙商西班牙對外銀行臺北分行",
    "372" => "大慶票券金融",
    "380" => "大陸商中國銀行臺北分行",
    "381" => "大陸商交通銀行臺北分行",
    "382" => "大陸商中國建設銀行臺北分行",
    "600" => "農金資訊",
    "700" => "中華郵政",
    "803" => "聯邦商業銀行",
    "805" => "遠東國際商業銀行",
    "806" => "元大商業銀行",
    "807" => "永豐商業銀行",
    "808" => "玉山商業銀行",
    "809" => "凱基商業銀行",
    "810" => "星展(台灣)商業銀行",
    "812" => "台新國際商業銀行",
    "815" => "日盛國際商業銀行",
    "816" => "安泰商業銀行",
    "822" => "中國信託商業銀行",
    "824" => "連線商業銀行",
    "826" => "樂天國際商業銀行",
    "952" => "農漁會南區資訊中心",
    "995" => "關貿網路",
    "996" => "財政部國庫署",
    "997" => "信用合作社聯合社南區"
  }.freeze

  attr_reader :epassbook_item, :client

  def initialize(epassbook_item, epassbook_client:)
    @epassbook_item = epassbook_item
    @client = epassbook_client
  end

  def import(sync: nil)
    Rails.logger.info("EpassbookItem::Importer #{epassbook_item.id} - starting import")

    login!

    stats = { stock_accounts: 0, bank_accounts: 0, fund_accounts: 0, errors: [] }

    import_stock_accounts(stats)
    import_bank_accounts(stats)
    import_fund_accounts(stats)

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

      broker_items = balance_result["accounts"] || []
      new_server_time = balance_result["lastServerTime"]

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

        holdings_value = (broker["items"] || []).sum do |item|
          item[7].to_d * item[17].to_s.delete(",").to_d
        end

        ea.assign_attributes(
          name: broker_name.presence || "證券帳戶 #{broker_account}",
          broker_no: broker_no,
          broker_account: broker_account,
          broker_name: broker_name,
          currency: "TWD",
          current_balance: holdings_value,
          raw_payload: broker
        )
        holdings_count = (broker["items"] || []).length
        Rails.logger.info("EpassbookItem::Importer - stock #{remote_id}: #{holdings_count} holdings from TR001")
        ea.save!
        stats[:stock_accounts] += 1

        begin
          import_stock_trades(ea)
        rescue Provider::Epassbook::EpassbookError => e
          Rails.logger.warn("EpassbookItem::Importer - stock #{remote_id} TR002 skipped: [#{e.code}] #{e.message}")
        end
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
      # TR002 items are arrays: [0]=postDate, [1]=txnSerNo
      seen = existing.map { |t| "#{t[0]}:#{t[1]}" }.to_set
      new_trades = trades.reject { |t| seen.include?("#{t[0]}:#{t[1]}") }

      return if new_trades.empty?

      merged = existing + new_trades
      epassbook_account.upsert_transactions_snapshot!({
        "trades" => merged,
        "fetched_at" => Time.current.iso8601
      })

      last = new_trades.last
      epassbook_account.update!(
        last_txn_post_date: last[0].to_s,
        last_txn_ser_no: last[1].to_s
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

          bank_display_name = TW_BANK_NAMES.fetch(bank_id, "銀行帳戶")
          ea.assign_attributes(
            name: "#{bank_display_name} #{account_no.last(4)}",
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

    # ── Fund accounts (TR051V1) ──

    def import_fund_accounts(stats)
      result = client.get_personal_fund_info
      fund_details = result["fundDetails"] || []
      return if fund_details.empty?

      remote_id = "fund_portfolio"
      ea = epassbook_item.epassbook_accounts.find_or_initialize_by(
        account_subtype: "fund",
        remote_id: remote_id
      )

      total_twd = result["totalAsset"].to_s.delete(",").to_d

      ea.assign_attributes(
        name: "基金帳戶",
        currency: "TWD",
        current_balance: total_twd,
        raw_payload: result
      )
      ea.save!

      stats[:fund_accounts] += 1
    rescue StandardError => e
      Rails.logger.error("EpassbookItem::Importer - fund import failed: #{e.message}")
      stats[:errors] << { type: "fund", remote_id: "fund_portfolio", message: e.message }
    end

    def handle_auth_error(error)
      auth_error_codes = %w[AU0001 AU0002 AU0003 AU0004 SESSION_EXPIRED INVALID_TOKEN]
      epassbook_item.update!(status: :requires_update) if auth_error_codes.include?(error.code)
    end
end

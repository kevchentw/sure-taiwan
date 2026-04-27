class TradePriceUpdateImport < Import
  def import!
    transaction do
      rows.find_each do |row|
        entry = trade_entry_for_external_id(row.external_id)
        next unless entry

        trade = entry.trade
        price = row.price.to_d
        fee = row.fee.present? ? row.fee.to_d : trade.fee
        amount = (trade.qty * price + fee).round(2)

        trade.update!(price: price, fee: fee)
        entry.update!(amount: amount)
        entry.mark_user_modified!
        entry.sync_account_later
      end
    end
  end

  def required_column_keys
    %i[external_id price fee]
  end

  def column_keys
    %i[external_id price]
  end

  def dry_run
    { trade_price_updates: rows_count }
  end

  def csv_template
    CSV.parse(<<~CSV, headers: true)
      external_id*,price*,fee
      provider-trade-123,150.00,1.00
      provider-trade-456,2500.00,0.00
    CSV
  end

  def trade_entry_for_external_id(external_id)
    return nil if external_id.blank?

    trade_entries_by_external_id[external_id.to_s]
  end

  private
    def trade_entries_by_external_id
      @trade_entries_by_external_id ||= family.entries
        .joins(:account)
        .where(entryable_type: "Trade")
        .where.not(external_id: [ nil, "" ])
        .index_by(&:external_id)
    end
end

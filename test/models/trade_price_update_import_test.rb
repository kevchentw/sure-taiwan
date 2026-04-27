require "test_helper"

class TradePriceUpdateImportTest < ActiveSupport::TestCase
  setup do
    @entry = entries(:trade)
    @entry.update!(external_id: "provider-trade-123", source: "provider")
    @import = families(:dylan_family).imports.create!(
      type: "TradePriceUpdateImport",
      raw_file_str: "external_id,price\nprovider-trade-123,250.50\n",
      external_id_col_label: "external_id",
      price_col_label: "price",
      number_format: "1,234.56"
    )
  end

  test "generates rows from external id and price columns" do
    @import.generate_rows_from_csv

    row = @import.rows.first

    assert_equal "provider-trade-123", row.external_id
    assert_equal "250.50", row.price
    assert row.valid?
  end

  test "requires price update rows to match an existing trade" do
    @import.generate_rows_from_csv
    row = @import.rows.first
    row.external_id = "missing"

    assert_not row.valid?
    assert_includes row.errors[:external_id], "does not match an existing trade"
  end

  test "publishing updates existing trade price and amount" do
    @import.generate_rows_from_csv

    assert_no_difference [ "Entry.count", "Trade.count" ] do
      @import.publish
    end

    @entry.reload

    assert_equal "complete", @import.reload.status
    assert_equal BigDecimal("250.50"), @entry.trade.price
    assert_equal BigDecimal("2505.0"), @entry.amount
    assert @entry.user_modified?
  end

  test "publishing updates fee when fee column is mapped" do
    @import.update!(
      raw_file_str: "external_id,price,fee\nprovider-trade-123,250.50,1.25\n",
      fee_col_label: "fee"
    )
    @import.generate_rows_from_csv

    @import.publish
    @entry.reload

    assert_equal BigDecimal("250.50"), @entry.trade.price
    assert_equal BigDecimal("1.25"), @entry.trade.fee
    assert_equal BigDecimal("2506.25"), @entry.amount
  end
end

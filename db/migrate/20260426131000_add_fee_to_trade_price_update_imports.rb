class AddFeeToTradePriceUpdateImports < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :fee, :string
    add_column :imports, :fee_col_label, :string
  end
end

class CreateEpassbookItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :epassbook_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid

      t.string :name

      t.string :institution_name,   default: "台灣ePassbook"
      t.string :institution_domain, default: "tdcc.com.tw"
      t.string :institution_url,    default: "https://www.tdcc.com.tw"
      t.string :institution_color,  default: "#D4343C"

      t.string  :status,                  default: "good"
      t.boolean :scheduled_for_deletion,  default: false
      t.boolean :pending_account_setup,   default: false

      # TDCC credentials (encrypted at rest via ActiveRecord Encryption)
      t.text :tdcc_user_id
      t.text :tdcc_password

      # Stable per-install device identifier (16-char hex, not sensitive)
      t.string :dev_id, null: false

      # Session token refreshed on every sync (encrypted)
      t.text :token_id

      # Incremental sync cursor for TR001 stock holdings
      t.string :last_stock_update_time

      t.jsonb :raw_payload

      t.timestamps
    end

    add_index :epassbook_items, :status

    create_table :epassbook_accounts, id: :uuid do |t|
      t.references :epassbook_item, null: false, foreign_key: true, type: :uuid

      # "stock" or "bank"
      t.string :account_subtype, null: false

      # Stable unique key within the item:
      #   stock: "<broker_no>:<broker_account>"
      #   bank:  "<bank_id>:<account_no>:<currency>"
      t.string :remote_id, null: false

      t.string  :name
      t.string  :currency, default: "TWD"
      t.decimal :current_balance, precision: 19, scale: 4

      # Stock-specific fields (from TR001)
      t.string :broker_no
      t.string :broker_account
      t.string :broker_name

      # Bank-specific fields (from TSP006)
      t.string :bank_id
      t.string :account_no

      # Incremental pagination cursors for TR002 trade detail
      t.string :last_txn_post_date
      t.string :last_txn_ser_no

      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :extra, default: {}, null: false

      t.timestamps
    end

    add_index :epassbook_accounts, :account_subtype
    add_index :epassbook_accounts, [ :epassbook_item_id, :remote_id ],
              unique: true,
              name: "index_epassbook_accounts_on_item_and_remote_id"
  end
end

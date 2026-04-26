class EpassbookAccount < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :epassbook_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :account_subtype, presence: true, inclusion: { in: %w[stock bank fund] }
  validates :remote_id, presence: true
  validates :remote_id, uniqueness: { scope: :epassbook_item_id }

  scope :stock_accounts, -> { where(account_subtype: "stock") }
  scope :bank_accounts,  -> { where(account_subtype: "bank") }
  scope :fund_accounts,  -> { where(account_subtype: "fund") }

  def current_account
    account
  end

  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "EpassbookAccount", provider_id: id)
      .tap do |ap|
        ap.account = acct
        ap.save!
      end
  rescue StandardError => e
    Rails.logger.warn("EpassbookAccount #{id}: failed to link account provider — #{e.class}: #{e.message}")
    nil
  end

  def stock?
    account_subtype == "stock"
  end

  def bank?
    account_subtype == "bank"
  end

  def fund?
    account_subtype == "fund"
  end

  def upsert_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def upsert_transactions_snapshot!(payload)
    update!(raw_transactions_payload: payload)
  end

  def display_name
    name.presence || remote_id
  end
end

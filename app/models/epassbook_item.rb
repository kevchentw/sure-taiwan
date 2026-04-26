class EpassbookItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :tdcc_user_id, deterministic: true
    encrypts :tdcc_password
    encrypts :token_id
    encrypts :raw_payload
  end

  before_validation :generate_dev_id, on: :create

  validates :tdcc_user_id, presence: true
  validates :tdcc_password, presence: true
  validates :dev_id, presence: true

  belongs_to :family

  has_many :epassbook_accounts, dependent: :destroy
  has_many :accounts, through: :epassbook_accounts

  scope :active,       -> { where(scheduled_for_deletion: false) }
  scope :syncable,     -> { active }
  scope :ordered,      -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_epassbook_data(sync:)
    EpassbookItem::Importer.new(self, epassbook_client: epassbook_client).import(sync: sync)
  rescue Provider::Epassbook::EpassbookError => e
    Rails.logger.error("EpassbookItem #{id} - import failed [#{e.code}]: #{e.message}")
    raise
  end

  def process_accounts
    linked = epassbook_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    linked.map do |ea|
      EpassbookAccount::Processor.new(ea).process
    rescue StandardError => e
      Rails.logger.error("EpassbookItem #{id} - failed to process account #{ea.id}: #{e.message}")
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.visible.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    rescue StandardError => e
      Rails.logger.error("EpassbookItem #{id} - failed to schedule sync for account #{account.id}: #{e.message}")
    end
  end

  def upsert_raw_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def save_token!(new_token)
    update!(token_id: new_token) if new_token.present? && new_token != token_id
  end

  def credentials_configured?
    tdcc_user_id.present? && tdcc_password.present? && dev_id.present?
  end

  def linked_accounts_count
    epassbook_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    epassbook_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    epassbook_accounts.count
  end

  def sync_status_summary
    total  = total_accounts_count
    linked = linked_accounts_count

    if total == 0
      I18n.t("epassbook_items.sync_status.no_accounts")
    elsif linked == total
      I18n.t("epassbook_items.sync_status.all_synced", count: linked)
    else
      I18n.t("epassbook_items.sync_status.partial_sync", linked_count: linked, unlinked_count: total - linked)
    end
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || "台灣ePassbook"
  end

  private

    def generate_dev_id
      self.dev_id = SecureRandom.uuid if dev_id.blank?
    end
end

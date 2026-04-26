class EpassbookItem::Syncer
  attr_reader :epassbook_item

  def initialize(epassbook_item)
    @epassbook_item = epassbook_item
  end

  def perform_sync(sync)
    # Phase 1: Verify credentials are present
    unless epassbook_item.credentials_configured?
      epassbook_item.update!(status: :requires_update)
      mark_failed(sync, "ePassbook credentials not configured")
      return
    end

    begin
      # Phase 2: Login + fetch stock holdings/trades + bank transactions
      epassbook_item.import_latest_epassbook_data(sync: sync)

      epassbook_item.update!(status: :good) if epassbook_item.requires_update?

      # Phase 3: Update setup flag
      unlinked = epassbook_item.epassbook_accounts
        .left_joins(:account_provider)
        .where(account_providers: { id: nil })
      linked = epassbook_item.epassbook_accounts
        .joins(:account_provider)
        .joins(:account)
        .merge(Account.visible)

      epassbook_item.update!(pending_account_setup: unlinked.any?)

      # Phase 4: Process linked accounts (upsert Entries / Holdings / Trades)
      epassbook_item.process_accounts if linked.any?

      # Phase 5: Schedule balance materialization
      if linked.any?
        epassbook_item.schedule_account_syncs(
          parent_sync: sync,
          window_start_date: sync.window_start_date,
          window_end_date: sync.window_end_date
        )
      end

    rescue Provider::Epassbook::EpassbookError => e
      Rails.logger.error("EpassbookItem::Syncer - API error [#{e.code}]: #{e.message}")
      mark_failed(sync, "[#{e.code}] #{e.message}")
      raise
    rescue StandardError => e
      Rails.logger.error("EpassbookItem::Syncer - unexpected error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      mark_failed(sync, e.message)
      raise
    end
  end

  def perform_post_sync
    # no-op
  end

  private

    def mark_failed(sync, error_message)
      return if sync.respond_to?(:status) && sync.status.to_s == "completed"

      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?
      sync.fail!  if sync.respond_to?(:may_fail?) && sync.may_fail?
      sync.update!(error: error_message) if sync.respond_to?(:error)
    end
end

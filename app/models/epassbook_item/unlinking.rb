module EpassbookItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    epassbook_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: "EpassbookAccount", provider_id: provider_account.id).to_a
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
        provider_link_ids: links.map(&:id)
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          Holding.where(account_provider_id: links.map(&:id)).update_all(account_provider_id: nil) if links.any?
          links.each(&:destroy!)
        end
      rescue StandardError => e
        Rails.logger.warn("EpassbookItem Unlinker: failed to unlink ##{provider_account.id}: #{e.class} - #{e.message}")
        result[:error] = e.message
      end
    end

    results
  end
end

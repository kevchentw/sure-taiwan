class Provider::EpassbookAdapter < Provider::Base
  include Provider::Syncable

  Provider::Factory.register("EpassbookAccount", self)

  def self.supported_account_types
    %w[Depository Investment]
  end

  def self.connection_configs(family:)
    [
      {
        key: "epassbook",
        name: "台灣ePassbook",
        description: "透過集保ePassbook同步台灣股票及銀行帳戶",
        can_connect: true,
        new_account_path: ->(_accountable_type, _return_to) {
          Rails.application.routes.url_helpers.new_epassbook_item_path
        },
        existing_account_path: ->(account_id) {
          Rails.application.routes.url_helpers.select_existing_account_epassbook_items_path(
            account_id: account_id
          )
        }
      }
    ]
  end

  def provider_name
    "epassbook"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_epassbook_item_path(item)
  end

  def item
    provider_account.epassbook_item
  end

  def can_delete_holdings?
    false
  end

  def institution_name
    item&.institution_name || "台灣ePassbook"
  end

  def institution_domain
    item&.institution_domain || "tdcc.com.tw"
  end

  def institution_url
    item&.institution_url
  end

  def institution_color
    item&.institution_color
  end

  def logo_url
    nil
  end
end

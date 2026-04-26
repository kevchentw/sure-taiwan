module EpassbookItem::Provided
  extend ActiveSupport::Concern

  def epassbook_client
    return nil unless credentials_configured?

    client = Provider::Epassbook.new(dev_id: dev_id)
    client.token_id = token_id
    client
  end
end

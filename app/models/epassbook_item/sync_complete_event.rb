class EpassbookItem::SyncCompleteEvent
  attr_reader :epassbook_item

  def initialize(epassbook_item)
    @epassbook_item = epassbook_item
  end

  def broadcast
    epassbook_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    epassbook_item.family.broadcast_sync_complete
  end
end

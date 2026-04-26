module Family::EpassbookConnectable
  extend ActiveSupport::Concern

  included do
    has_many :epassbook_items, dependent: :destroy
  end
end

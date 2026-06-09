class Issue < ApplicationRecord
  belongs_to :epic

  scope :active, -> { where(removed_at: nil) }
end

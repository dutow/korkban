class AllowNullEpicOnIssues < ActiveRecord::Migration[8.1]
  def change
    change_column_null :issues, :epic_id, true
  end
end

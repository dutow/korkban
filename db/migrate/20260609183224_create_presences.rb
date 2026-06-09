class CreatePresences < ActiveRecord::Migration[8.1]
  def change
    create_table :presences do |t|
      t.datetime :last_seen_at, null: false

      t.timestamps
    end
  end
end

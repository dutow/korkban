require Rails.root.join("app/lib/pgboard/config").to_s

PGBOARD_CONFIG = Pgboard::Config.load_from_path(
  Rails.root.join("config", "pgboard.yml")
)

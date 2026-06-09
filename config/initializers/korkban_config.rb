require Rails.root.join("app/lib/korkban/config").to_s

KORKBAN_CONFIG = Korkban::Config.load_from_path(
  Rails.root.join("config", "korkban.yml")
)

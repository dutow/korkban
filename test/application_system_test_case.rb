require "test_helper"
require "capybara/rails"
require "selenium/webdriver"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium,
            using: :headless_chrome,
            screen_size: [1400, 900],
            options: {
              browser: :remote,
              url: ENV.fetch("SELENIUM_REMOTE_URL", "http://chromium:4444/wd/hub")
            }

  Capybara.server_host = "0.0.0.0"
  Capybara.app_host    = "http://#{ENV.fetch("APP_HOSTNAME", "app")}"
end

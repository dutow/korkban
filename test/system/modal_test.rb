require "application_system_test_case"

class ModalSystemTest < ApplicationSystemTestCase
  fixtures :epics, :issues

  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "u1",
      info: { email: "alice@example.com", name: "Alice" }
    )
    visit "/auth/google_oauth2/callback"
  end

  test "clicking a postit opens the modal frame" do
    visit "/"
    find(".kb-card", text: "Fresh task").click
    assert_selector "turbo-frame#modal", text: "Fresh task"
  end
end

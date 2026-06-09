require "test_helper"

class IssuesControllerTest < ActionDispatch::IntegrationTest
  fixtures :epics, :issues

  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "u1",
      info: { email: "alice@example.com", name: "Alice" }
    )
    get "/auth/google_oauth2/callback"
  end

  test "renders modal frame for an issue" do
    get "/issues/PG-10", headers: { "Turbo-Frame" => "modal" }
    assert_response :success
    assert_match "Fresh task", response.body
  end

  test "returns 404 for unknown issue" do
    get "/issues/UNKNOWN"
    assert_response :not_found
  end
end

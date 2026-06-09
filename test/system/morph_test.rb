require "application_system_test_case"

# This test verifies that a turbo-stream morph broadcast applied while a modal
# is open does NOT close the modal. For the broadcast to reach the browser,
# ActionCable must actually carry messages cross-process — the default `async`
# cable adapter does this within a single Ruby process. If the chromium
# container holds the WebSocket and the test process broadcasts here, the
# message lands.
#
# If this test fails with "modal disappeared", first verify that the cable
# adapter in `config/cable.yml` for the test env uses `async` (default),
# and that turbo_stream_from is rendered into the visited page.

class MorphSystemTest < ApplicationSystemTestCase
  fixtures :epics, :issues

  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "u1",
      info: { email: "alice@example.com", name: "Alice" }
    )
    visit "/auth/google_oauth2/callback"
  end

  test "morph applied while modal open does not close the modal" do
    visit "/"
    find(".pg-card", text: "Fresh task").click
    assert_selector "turbo-frame#modal", text: "Fresh task"

    Turbo::StreamsChannel.broadcast_render_to(
      "board",
      partial: "board/board_morph",
      locals: {
        presenter: BoardPresenter.new(
          epics: Epic.active.ordered.includes(:issues),
          status_map: PGBOARD_CONFIG.board.status_map,
          new_statuses: PGBOARD_CONFIG.board.new_statuses,
          done_statuses: PGBOARD_CONFIG.board.done_statuses,
          staleness: StalenessCalculator.new(now: Time.current,
                                             somewhat_days: 7, really_days: 21)
        ),
        last_sync: SyncRun.create!(started_at: Time.current,
                                   finished_at: Time.current, ok: true)
      }
    )

    sleep 0.5
    assert_selector "turbo-frame#modal", text: "Fresh task"
  end
end

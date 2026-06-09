require "test_helper"

class BoardPresenterTest < ActiveSupport::TestCase
  fixtures :epics, :issues

  STATUS_MAP = {
    "To Do" => "new",
    "In Progress" => "in_progress",
    "In Review" => "review",
    "Done" => "done"
  }

  def build_presenter
    BoardPresenter.new(
      epics: Epic.active.ordered.includes(:issues),
      status_map: STATUS_MAP,
      new_statuses: ["new"],
      done_statuses: ["done"],
      staleness: StalenessCalculator.new(
        now: Time.current, somewhat_days: 7, really_days: 21
      )
    )
  end

  test "columns are ordered by epic priority and exclude removed" do
    cols = build_presenter.columns
    assert_equal %w[PG-1 PG-2], cols.map { |c| c.epic.jira_key }
  end

  test "issues are grouped by display status with new/done partitioned" do
    cols = build_presenter.columns
    epic1 = cols.first
    assert_equal ["PG-12"], epic1.new_issues.map(&:jira_key)
    assert_equal ["PG-13"], epic1.done_issues.map(&:jira_key)
    assert_equal ["PG-10"], epic1.middle_groups["in_progress"].map(&:jira_key)
    assert_equal ["PG-11"], epic1.middle_groups["review"].map(&:jira_key)
  end

  test "warnings include unmapped statuses" do
    warnings = build_presenter.warnings
    assert_includes warnings.map(&:issue_key), "PG-14"
  end

  test "staleness bucket is attached per issue" do
    cols = build_presenter.columns
    by_key = cols.flat_map(&:all_issues).index_by(&:jira_key)
    assert_equal :fresh,    by_key["PG-10"].staleness
    assert_equal :really,   by_key["PG-11"].staleness
    assert_equal :fresh,    by_key["PG-12"].staleness # new + ignore rule
  end
end

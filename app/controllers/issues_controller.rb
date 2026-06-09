class IssuesController < ApplicationController
  ACCENT_PALETTE = %w[#6366f1 #e11d48 #d97706 #0ea5e9 #8b5cf6 #0d9488 #10b981 #ea580c #c026d3 #64748b].freeze

  def show
    @issue = Issue.active.find_by(jira_key: params[:jira_key])
    if @issue.nil?
      render plain: "Not found", status: :not_found
      return
    end

    @display_status = PGBOARD_CONFIG.board.status_map[@issue.jira_status] || "unknown"

    @staleness = StalenessCalculator.new(
      now: Time.current,
      somewhat_days: PGBOARD_CONFIG.board.staleness.somewhat_days,
      really_days: PGBOARD_CONFIG.board.staleness.really_days,
      ignore_for_new: PGBOARD_CONFIG.board.ignore_staleness_for_new_issues,
      new_display_statuses: PGBOARD_CONFIG.board.new_statuses
    ).bucket(
      transitioned_at: @issue.status_changed_at_jira || @issue.created_at_jira || Time.current,
      display_status: @display_status
    )

    @epic_accent = ACCENT_PALETTE[(@issue.epic.jira_key.to_s.bytes.sum % ACCENT_PALETTE.size)]

    render layout: false
  end
end

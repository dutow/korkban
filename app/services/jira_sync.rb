class JiraSync
  EPIC_FIELDS  = %w[summary status priority].freeze
  ISSUE_FIELDS = %w[summary status issuetype assignee priority created].freeze

  def initialize(epic_query: PGBOARD_CONFIG.board.epic_query, client: JiraClient.new)
    @epic_query = epic_query
    @client = client
  end

  def run!
    run = SyncRun.create!(started_at: Time.current, ok: false, fetched_count: 0)
    fetched = 0
    now = Time.current

    epics_jira = @client.search_all(@epic_query, fields: EPIC_FIELDS)
    seen_epic_keys = []

    epics_jira.each do |je|
      epic = upsert_epic(je, now)
      seen_epic_keys << epic.jira_key

      child_jql = %Q{parent = "#{epic.jira_key}"}
      children = @client.search_all(child_jql, fields: ISSUE_FIELDS)
      seen_issue_keys = []
      children.each do |ji|
        upsert_issue(ji, epic, now)
        seen_issue_keys << ji.key
      end
      epic.issues.active.where.not(jira_key: seen_issue_keys).update_all(removed_at: now)
      fetched += children.size
    end

    Epic.active.where.not(jira_key: seen_epic_keys).update_all(removed_at: now)

    run.update!(finished_at: Time.current, ok: true, fetched_count: fetched)
    BoardSnapshot.bump!
    Turbo::StreamsChannel.broadcast_render_to(
      "board",
      partial: "board/board_morph",
      locals: { presenter: build_presenter, last_sync: run }
    )
    run
  rescue => e
    run.update!(finished_at: Time.current, ok: false, error_message: e.message)
    Rails.logger.error("[JiraSync] #{e.class}: #{e.message}")
    run
  end

  private

  def upsert_epic(je, now)
    epic = Epic.find_or_initialize_by(jira_key: je.key)
    epic.assign_attributes(
      name: je.fields["summary"],
      jira_status: je.fields.dig("status", "name"),
      priority: priority_int(je.fields["priority"]),
      raw_fields: je.fields,
      last_seen_in_query_at: now,
      removed_at: nil
    )
    epic.save!
    epic
  end

  def upsert_issue(ji, epic, now)
    issue = Issue.find_or_initialize_by(jira_key: ji.key)
    new_status = ji.fields.dig("status", "name")
    status_changed = issue.persisted? && issue.jira_status != new_status
    first_seen = issue.new_record?

    issue.assign_attributes(
      epic: epic,
      summary: ji.fields["summary"],
      jira_status: new_status,
      issue_type: ji.fields.dig("issuetype", "name"),
      assignee_username: ji.fields.dig("assignee", "displayName") || ji.fields.dig("assignee", "name"),
      priority: priority_int(ji.fields["priority"]),
      created_at_jira: parse_time(ji.fields["created"]) || issue.created_at_jira || now,
      raw_fields: ji.fields,
      last_seen_in_query_at: now,
      removed_at: nil
    )
    if first_seen || status_changed
      issue.status_changed_at_jira = now
    end
    issue.save!
    issue
  end

  def priority_int(p)
    return nil if p.blank?
    Integer(p["id"]) rescue nil
  end

  def parse_time(s)
    Time.parse(s) rescue nil
  end

  def build_presenter
    BoardPresenter.new(
      epics: Epic.active.ordered.includes(:issues),
      status_map: PGBOARD_CONFIG.board.status_map,
      new_statuses: PGBOARD_CONFIG.board.new_statuses,
      done_statuses: PGBOARD_CONFIG.board.done_statuses,
      staleness: StalenessCalculator.new(
        now: Time.current,
        somewhat_days: PGBOARD_CONFIG.board.staleness.somewhat_days,
        really_days: PGBOARD_CONFIG.board.staleness.really_days
      )
    )
  end
end

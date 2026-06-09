require "test_helper"
require "webmock/minitest"

class JiraSyncTest < ActiveSupport::TestCase
  setup do
    WebMock.disable_net_connect!
    Issue.delete_all
    Epic.delete_all
  end

  test "upserts epics and their children" do
    # Permissive stubs; jira-ruby's exact URL format is internal.
    stub_request(:get, %r{/search}).to_return do |req|
      decoded = CGI.unescape(req.uri.to_s)
      body = case decoded
             when /labels.*Priority/i
               { "issues" => [
                   { "key" => "PG-1", "fields" => { "summary" => "Epic A",
                                                    "status" => { "name" => "In Progress" },
                                                    "priority" => { "id" => "1" } } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             when /parent\s*=\s*"?PG-1"?/i
               { "issues" => [
                   { "key" => "PG-10", "fields" => { "summary" => "Child A",
                                                     "status" => { "name" => "To Do" },
                                                     "issuetype" => { "name" => "Task" },
                                                     "assignee" => { "name" => "alice" } } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             else
               { "issues" => [], "total" => 0, "startAt" => 0, "maxResults" => 50 }
             end
      { status: 200, body: body.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    JiraSync.new(epic_query: 'project = PG AND labels = "Priority"').run!

    assert_equal 1, Epic.count
    assert_equal "Epic A", Epic.first.name
    assert_equal 1, Issue.count
    assert_equal "PG-10", Issue.first.jira_key
  end

  test "uses last status change from changelog for status_changed_at_jira" do
    changed_at = "2026-06-03T10:00:00.000+0000"
    created_at = "2026-05-01T09:00:00.000+0000"

    stub_request(:get, %r{/search}).to_return do |req|
      decoded = CGI.unescape(req.uri.to_s)
      body = case decoded
             when /labels.*Priority/i
               { "issues" => [
                   { "key" => "PG-1", "fields" => { "summary" => "Epic A",
                                                    "status" => { "name" => "In Progress" },
                                                    "priority" => { "id" => "1" } } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             when /parent\s*=\s*"?PG-1"?/i
               { "issues" => [
                   { "key" => "PG-10",
                     "fields" => { "summary" => "Child A",
                                   "status" => { "name" => "In Progress" },
                                   "issuetype" => { "name" => "Task" },
                                   "created" => created_at },
                     "changelog" => { "histories" => [
                       { "created" => "2026-05-02T09:00:00.000+0000",
                         "items" => [{ "field" => "assignee", "toString" => "alice" }] },
                       { "created" => changed_at,
                         "items" => [{ "field" => "status", "fromString" => "To Do",
                                       "toString" => "In Progress" }] }
                     ] } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             else
               { "issues" => [], "total" => 0, "startAt" => 0, "maxResults" => 50 }
             end
      { status: 200, body: body.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    JiraSync.new(epic_query: 'project = PG AND labels = "Priority"').run!

    issue = Issue.find_by!(jira_key: "PG-10")
    assert_equal Time.parse(changed_at), issue.status_changed_at_jira
  end

  test "leaves status_changed_at_jira nil when changelog has no status change" do
    created_at = "2026-05-01T09:00:00.000+0000"

    stub_request(:get, %r{/search}).to_return do |req|
      decoded = CGI.unescape(req.uri.to_s)
      body = case decoded
             when /labels.*Priority/i
               { "issues" => [
                   { "key" => "PG-1", "fields" => { "summary" => "Epic A",
                                                    "status" => { "name" => "To Do" },
                                                    "priority" => { "id" => "1" } } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             when /parent\s*=\s*"?PG-1"?/i
               { "issues" => [
                   { "key" => "PG-11",
                     "fields" => { "summary" => "Child B",
                                   "status" => { "name" => "To Do" },
                                   "issuetype" => { "name" => "Task" },
                                   "created" => created_at },
                     "changelog" => { "histories" => [] } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             else
               { "issues" => [], "total" => 0, "startAt" => 0, "maxResults" => 50 }
             end
      { status: 200, body: body.to_json,
        headers: { "Content-Type" => "application/json" } }
    end

    JiraSync.new(epic_query: 'project = PG AND labels = "Priority"').run!

    issue = Issue.find_by!(jira_key: "PG-11")
    assert_nil issue.status_changed_at_jira
    assert_equal Time.parse(created_at), issue.created_at_jira
  end

  test "records a SyncRun on success" do
    stub_request(:get, %r{/search}).to_return(
      status: 200,
      body: { "issues" => [], "total" => 0, "startAt" => 0, "maxResults" => 50 }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_difference -> { SyncRun.ok.count }, 1 do
      JiraSync.new(epic_query: 'project = PG').run!
    end
  end

  test "marks SyncRun as failed when JIRA errors" do
    stub_request(:get, %r{/search}).to_return(status: 500, body: "boom")

    assert_difference -> { SyncRun.count }, 1 do
      assert_nothing_raised { JiraSync.new(epic_query: 'project = PG').run! }
    end
    assert_not SyncRun.most_recent.first.ok
  end
end

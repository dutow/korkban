# pgboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:executing-plans to implement this plan task-by-task.

**Goal:** Build a Rails 8 read-only Kanban-style board for our JIRA project,
following the design in
[`2026-06-09-pgboard-design.md`](2026-06-09-pgboard-design.md).

**Architecture:** Rails 8 + SQLite (4 split DBs) + SolidQueue recurring poller
+ Turbo morph broadcasts. The SQLite snapshot is the cache; controllers never
call JIRA directly. Auth via `omniauth-google-oauth2` with a domain
allow-list.

**Tech Stack:** Ruby 3.3, Rails 8.x, SQLite, SolidQueue, Turbo (morph),
Stimulus, `omniauth-google-oauth2`, `jira-ruby`, Faraday-free (gem provides
its own), Capybara + Selenium against a `chromium` container, Docker Compose,
Caddy (prod TLS), Taskfile.

---

## Conventions used in this plan

- All paths are **relative to the Rails app root** `/storage/webd/pgboard/pgboard/`.
- The repo's only branch is `main`. We commit frequently after each task's
  green test run.
- Inside the dev container, run things via `task` shortcuts. Outside, the same
  commands are documented under each step so you can fall back if needed.
- Test framework: Rails default (Minitest). Fixtures for DB seed data, no
  mocks at the DB layer. JIRA HTTP responses are stubbed via WebMock at the
  HTTP layer beneath `jira-ruby`.
- Time zone: UTC everywhere. `config.time_zone = "UTC"` set in Task 0.

## Pre-flight check

```bash
cd /storage/webd/pgboard/pgboard
git log --oneline   # expect: one commit (the design doc)
git status          # expect: clean
ruby -v             # expect: 3.3.x (install via your preferred method if missing)
rails -v            # expect: 8.x (install Rails 8 if missing: `gem install rails -v "~> 8.0"`)
docker --version    # expect: any recent
docker compose version
```

If any tool is missing, install it before starting. The plan assumes these are
present on the host (Docker handles them inside the container after Task 1).

---

## Task 0: Generate the Rails app

**Files:**
- Create: `Gemfile`, `Gemfile.lock`, `config/*`, `app/*`, etc. (full `rails new` output)
- Modify: `config/application.rb` (time zone)
- Modify: `config/environments/test.rb` (system test driver port)

**Step 1: Generate Rails skeleton in-place**

The directory `/storage/webd/pgboard/pgboard` already exists with just a `.git`
and the design doc under `docs/`. `rails new` insists on an empty dir or
forcing — we'll use `--force`.

Run:
```bash
cd /storage/webd/pgboard/pgboard
rails new . --force --database=sqlite3 --skip-test=false --skip-bundle --skip-git --css=tailwind --javascript=importmap
```

Notes:
- `--css=tailwind` keeps styling self-contained, no Node build step.
- `--javascript=importmap` matches the design.
- `--skip-git` because we already have a repo.
- `--skip-bundle` because we'll run `bundle install` after editing the Gemfile.

**Step 2: Pin time zone to UTC**

Edit `config/application.rb`. Inside the `class Application < Rails::Application`
block, add:

```ruby
config.time_zone = "UTC"
config.active_record.default_timezone = :utc
```

**Step 3: Add core gems**

Append to `Gemfile` (top-level, not under any group):

```ruby
gem "jira-ruby"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"
```

Append to the `:development, :test` group:

```ruby
gem "webmock"
```

Append to the `:test` group:

```ruby
gem "capybara"
gem "selenium-webdriver"
```

**Step 4: Install gems**

Run:
```bash
bundle install
```

Expected: bundle resolves, `Gemfile.lock` written.

**Step 5: First sanity check**

Run:
```bash
bin/rails about
```

Expected: prints Rails version, DB adapter SQLite, no errors.

**Step 6: Commit**

```bash
git add -A
git commit -m "Generate Rails 8 skeleton with importmap+tailwind, UTC time zone"
```

Expected: a sizeable commit (the skeleton). `git log --oneline` shows 2
commits now.

---

## Task 1: Dev Docker setup

**Files:**
- Create: `Dockerfile.dev`
- Create: `docker-compose.yml`
- Create: `.dockerignore` (if `rails new` didn't make a usable one — overwrite anyway)

**Step 1: Write `Dockerfile.dev`**

```dockerfile
# Dockerfile.dev — image for local development
FROM ruby:3.3-slim

ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      git \
      libsqlite3-dev \
      libyaml-dev \
      pkg-config \
      sqlite3 \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
```

**Step 2: Write `docker-compose.yml` (dev)**

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    ports:
      - "3000:3000"
    volumes:
      - .:/app
      - bundle:/usr/local/bundle
      - ./storage:/app/storage
    environment:
      RAILS_ENV: development
      JIRA_BASE_URL: ${JIRA_BASE_URL:-https://example.atlassian.net}
      JIRA_EMAIL: ${JIRA_EMAIL:-jira@example.com}
      JIRA_API_TOKEN: ${JIRA_API_TOKEN:-changeme}
      GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID:-changeme}
      GOOGLE_CLIENT_SECRET: ${GOOGLE_CLIENT_SECRET:-changeme}
    depends_on:
      - chromium

  chromium:
    image: selenium/standalone-chromium:latest
    shm_size: "2gb"
    ports:
      - "4444:4444"

volumes:
  bundle:
```

**Step 3: Tighten `.dockerignore`**

Overwrite `.dockerignore` with:

```
.git
log/*
tmp/*
storage/*
node_modules
.bundle
test/screenshots
```

**Step 4: Verify the dev image builds**

Run:
```bash
docker compose build app
```

Expected: builds without errors. (First run is slow; subsequent runs cache.)

**Step 5: Verify the dev server boots inside the container**

Run:
```bash
docker compose up app
```

Open http://localhost:3000 in a browser. Expect the default Rails welcome
page. Stop with `Ctrl+C`.

**Step 6: Commit**

```bash
git add Dockerfile.dev docker-compose.yml .dockerignore
git commit -m "Add dev Dockerfile and docker-compose with chromium service"
```

---

## Task 2: Taskfile scaffolding

**Files:**
- Create: `Taskfile.yml`

**Step 1: Write `Taskfile.yml`**

Only the tasks we know we need now. We'll grow it in later tasks.

```yaml
version: "3"

tasks:
  dev:
    desc: "Run dev server via docker compose"
    cmds:
      - docker compose up app

  shell:
    desc: "Open a bash shell in the dev container"
    cmds:
      - docker compose run --rm app bash

  console:
    desc: "Rails console"
    cmds:
      - docker compose run --rm app bin/rails console

  migrate:
    desc: "Run pending migrations"
    cmds:
      - docker compose run --rm app bin/rails db:migrate

  test:
    desc: "Run all tests (unit + system)"
    cmds:
      - docker compose run --rm app bin/rails test test:system

  logs:
    desc: "Tail app logs"
    cmds:
      - docker compose logs -f app
```

**Step 2: Verify Task picks it up**

Run on the host (Task is a host-side tool, not a container tool):
```bash
task --list
```

Expected: lists `dev`, `shell`, `console`, `migrate`, `test`, `logs` with
descriptions. If `task` isn't installed, install
https://taskfile.dev/installation/ first.

**Step 3: Commit**

```bash
git add Taskfile.yml
git commit -m "Add Taskfile with common dev/test/console tasks"
```

---

## Task 3: Config singleton + `config/pgboard.yml`

**Files:**
- Create: `config/pgboard.yml`
- Create: `config/pgboard.example.yml`
- Create: `app/lib/pgboard/config.rb`
- Create: `config/initializers/pgboard_config.rb`
- Create: `test/lib/pgboard/config_test.rb`

**Step 1: Write the failing test**

`test/lib/pgboard/config_test.rb`:

```ruby
require "test_helper"

class Pgboard::ConfigTest < ActiveSupport::TestCase
  def fixture_yaml
    <<~YAML
      jira:
        base_url_env: JIRA_BASE_URL
        email_env: JIRA_EMAIL
        api_token_env: JIRA_API_TOKEN
      auth:
        allowed_domains: ["example.com"]
        allowed_emails: []
        google_client_id_env: GOOGLE_CLIENT_ID
        google_client_secret_env: GOOGLE_CLIENT_SECRET
      polling:
        tick_seconds: 60
        active_window_minutes: 5
        idle_interval_minutes: 60
      board:
        epic_query: 'project = PG'
        users:
          - { jira_username: "alice", display_name: "Alice" }
        status_map:
          "To Do": "new"
          "Done":  "done"
        new_statuses:  ["new"]
        done_statuses: ["done"]
        staleness:
          somewhat_days: 7
          really_days:   21
        ignore_staleness_for_new_issues: true
    YAML
  end

  test "loads and exposes typed sections" do
    cfg = Pgboard::Config.load_from_string(fixture_yaml)
    assert_equal ["example.com"], cfg.auth.allowed_domains
    assert_equal 60,              cfg.polling.tick_seconds
    assert_equal "new",           cfg.board.status_map.fetch("To Do")
    assert_equal 7,               cfg.board.staleness.somewhat_days
    assert_equal "alice",         cfg.board.users.first.jira_username
  end

  test "raises MissingKey when a required key is absent" do
    yaml = fixture_yaml.sub("epic_query: 'project = PG'", "")
    assert_raises(Pgboard::Config::MissingKey) do
      Pgboard::Config.load_from_string(yaml)
    end
  end

  test "resolves env-backed JIRA credentials" do
    ENV["JIRA_API_TOKEN"] = "secret-token"
    cfg = Pgboard::Config.load_from_string(fixture_yaml)
    assert_equal "secret-token", cfg.jira.api_token
  ensure
    ENV.delete("JIRA_API_TOKEN")
  end
end
```

**Step 2: Run the test to verify it fails**

Run:
```bash
docker compose run --rm app bin/rails test test/lib/pgboard/config_test.rb
```

Expected: `NameError: uninitialized constant Pgboard`.

**Step 3: Implement `Pgboard::Config`**

`app/lib/pgboard/config.rb`:

```ruby
require "yaml"
require "ostruct"

module Pgboard
  class Config
    class MissingKey < StandardError; end

    REQUIRED_PATHS = [
      %w[jira base_url_env],
      %w[jira email_env],
      %w[jira api_token_env],
      %w[auth allowed_domains],
      %w[auth google_client_id_env],
      %w[auth google_client_secret_env],
      %w[polling tick_seconds],
      %w[polling active_window_minutes],
      %w[polling idle_interval_minutes],
      %w[board epic_query],
      %w[board users],
      %w[board status_map],
      %w[board new_statuses],
      %w[board done_statuses],
      %w[board staleness somewhat_days],
      %w[board staleness really_days]
    ].freeze

    class << self
      def load_from_path(path)
        load_from_string(File.read(path))
      end

      def load_from_string(yaml)
        raw = YAML.safe_load(yaml, permitted_classes: [Symbol], aliases: true)
        validate!(raw)
        new(raw)
      end

      private

      def validate!(raw)
        REQUIRED_PATHS.each do |path|
          node = raw
          path.each do |key|
            unless node.is_a?(Hash) && node.key?(key)
              raise MissingKey, "Missing required config key: #{path.join('.')}"
            end
            node = node[key]
          end
        end
      end
    end

    def initialize(raw)
      @raw = raw
    end

    def jira
      @jira ||= JiraSection.new(@raw["jira"])
    end

    def auth
      @auth ||= AuthSection.new(@raw["auth"])
    end

    def polling
      @polling ||= struct(@raw["polling"])
    end

    def board
      @board ||= BoardSection.new(@raw["board"])
    end

    private

    def struct(hash)
      OpenStruct.new(hash)
    end

    class JiraSection
      def initialize(h) = @h = h
      def base_url   = ENV.fetch(@h["base_url_env"])
      def email      = ENV.fetch(@h["email_env"])
      def api_token  = ENV.fetch(@h["api_token_env"])
    end

    class AuthSection
      def initialize(h) = @h = h
      def allowed_domains = @h["allowed_domains"] || []
      def allowed_emails  = @h["allowed_emails"]  || []
      def google_client_id     = ENV.fetch(@h["google_client_id_env"])
      def google_client_secret = ENV.fetch(@h["google_client_secret_env"])
    end

    class BoardSection
      def initialize(h) = @h = h
      def epic_query  = @h["epic_query"]
      def users       = (@h["users"] || []).map { |u| OpenStruct.new(u) }
      def status_map  = @h["status_map"]
      def new_statuses  = @h["new_statuses"]
      def done_statuses = @h["done_statuses"]
      def staleness  = OpenStruct.new(@h["staleness"])
      def ignore_staleness_for_new_issues
        @h.fetch("ignore_staleness_for_new_issues", true)
      end
    end
  end
end
```

**Step 4: Add the initializer**

`config/initializers/pgboard_config.rb`:

```ruby
require "pgboard/config"

PGBOARD_CONFIG = Pgboard::Config.load_from_path(
  Rails.root.join("config", "pgboard.yml")
)
```

**Step 5: Provide an example config and a default dev config**

`config/pgboard.example.yml`:

```yaml
jira:
  base_url_env: JIRA_BASE_URL
  email_env: JIRA_EMAIL
  api_token_env: JIRA_API_TOKEN

auth:
  allowed_domains: ["example.com"]
  allowed_emails: []
  google_client_id_env: GOOGLE_CLIENT_ID
  google_client_secret_env: GOOGLE_CLIENT_SECRET

polling:
  tick_seconds: 60
  active_window_minutes: 5
  idle_interval_minutes: 60

board:
  epic_query: 'project = PG AND labels = "Priority" AND status != Done'
  users:
    - { jira_username: "alice", display_name: "Alice" }
    - { jira_username: "bob",   display_name: "Bob" }
  status_map:
    "To Do":       "new"
    "In Progress": "in_progress"
    "In Review":   "review"
    "Done":        "done"
  new_statuses:  ["new"]
  done_statuses: ["done"]
  staleness:
    somewhat_days: 7
    really_days:   21
  ignore_staleness_for_new_issues: true
```

Copy it as the working dev config:

```bash
cp config/pgboard.example.yml config/pgboard.yml
```

**Step 6: Autoload `app/lib`**

Edit `config/application.rb`, inside the `Application` class:

```ruby
config.autoload_paths += %W[#{config.root}/app/lib]
config.eager_load_paths += %W[#{config.root}/app/lib]
```

**Step 7: Run the test to verify it passes**

Run:
```bash
docker compose run --rm app bin/rails test test/lib/pgboard/config_test.rb
```

Expected: 3 runs, 0 failures.

**Step 8: Commit**

```bash
git add app/lib config/pgboard.example.yml config/pgboard.yml \
        config/initializers/pgboard_config.rb config/application.rb \
        test/lib
git commit -m "Add Pgboard::Config loader with env-backed secrets and validation"
```

---

## Task 4: Domain models + migrations

**Files:**
- Create: 5 migration files via `bin/rails g model`
- Create: `app/models/{epic,issue,sync_run,presence,board_snapshot}.rb`
- Create: `test/models/epic_test.rb`, `test/models/issue_test.rb`
- Modify: `db/seeds.rb` (no-op but documented)

**Step 1: Write failing tests for `Epic` / `Issue`**

`test/models/epic_test.rb`:

```ruby
require "test_helper"

class EpicTest < ActiveSupport::TestCase
  test "active scope excludes removed epics" do
    active  = Epic.create!(jira_key: "PG-1", name: "A", priority: 1, jira_status: "To Do")
    removed = Epic.create!(jira_key: "PG-2", name: "B", priority: 2, jira_status: "Done",
                           removed_at: Time.current)
    assert_includes Epic.active, active
    assert_not_includes Epic.active, removed
  end

  test "ordered scope sorts by priority asc, name asc" do
    c = Epic.create!(jira_key: "PG-3", name: "Charlie", priority: 2, jira_status: "To Do")
    a = Epic.create!(jira_key: "PG-1", name: "Alpha",   priority: 1, jira_status: "To Do")
    b = Epic.create!(jira_key: "PG-2", name: "Bravo",   priority: 1, jira_status: "To Do")
    assert_equal [a, b, c], Epic.ordered.to_a
  end
end
```

`test/models/issue_test.rb`:

```ruby
require "test_helper"

class IssueTest < ActiveSupport::TestCase
  setup do
    @epic = Epic.create!(jira_key: "PG-1", name: "Epic", priority: 1, jira_status: "To Do")
  end

  test "belongs to epic and exposes raw_fields as json" do
    issue = Issue.create!(
      jira_key: "PG-10", epic: @epic,
      issue_type: "Task", summary: "Do it",
      jira_status: "To Do",
      raw_fields: { "labels" => ["foo"] }
    )
    assert_equal "foo", Issue.find(issue.id).raw_fields["labels"].first
  end
end
```

**Step 2: Run tests to verify they fail**

Run:
```bash
docker compose run --rm app bin/rails test test/models
```

Expected: `NameError: uninitialized constant Epic`.

**Step 3: Generate migrations**

Run inside the container:
```bash
docker compose run --rm app bin/rails g model Epic \
  jira_key:string:uniq name:string priority:integer \
  jira_status:string raw_fields:json \
  last_seen_in_query_at:datetime removed_at:datetime

docker compose run --rm app bin/rails g model Issue \
  jira_key:string:uniq epic:references issue_type:string \
  summary:string jira_status:string assignee_username:string \
  priority:integer created_at_jira:datetime \
  status_changed_at_jira:datetime raw_fields:json \
  last_seen_in_query_at:datetime removed_at:datetime

docker compose run --rm app bin/rails g model SyncRun \
  started_at:datetime finished_at:datetime ok:boolean \
  error_message:text fetched_count:integer

docker compose run --rm app bin/rails g model Presence \
  last_seen_at:datetime

docker compose run --rm app bin/rails g model BoardSnapshot \
  version:integer
```

After generation, edit each migration to:
- Add `null: false` and sensible defaults on the not-null fields
- Add indexes on `Epic#removed_at`, `Issue#removed_at`, `Issue#jira_status`

Edit `db/migrate/*_create_issues.rb`'s `t.references :epic` line to:

```ruby
t.references :epic, null: false, foreign_key: true
```

**Step 4: Run migrations**

```bash
task migrate
```

Expected: schema written to `db/schema.rb`.

**Step 5: Flesh out models**

`app/models/epic.rb`:

```ruby
class Epic < ApplicationRecord
  has_many :issues, dependent: :destroy

  scope :active,  -> { where(removed_at: nil) }
  scope :ordered, -> { order(priority: :asc, name: :asc) }
end
```

`app/models/issue.rb`:

```ruby
class Issue < ApplicationRecord
  belongs_to :epic

  scope :active, -> { where(removed_at: nil) }
end
```

`app/models/sync_run.rb`:

```ruby
class SyncRun < ApplicationRecord
  scope :ok,         -> { where(ok: true) }
  scope :most_recent, -> { order(started_at: :desc) }
end
```

`app/models/presence.rb`:

```ruby
class Presence < ApplicationRecord
  def self.singleton
    first || create!(last_seen_at: Time.at(0))
  end

  def self.touch_now!
    singleton.update!(last_seen_at: Time.current)
  end
end
```

`app/models/board_snapshot.rb`:

```ruby
class BoardSnapshot < ApplicationRecord
  def self.singleton
    first || create!(version: 0)
  end

  def self.bump!
    singleton.tap { |s| s.update!(version: s.version + 1) }
  end
end
```

**Step 6: Run tests to verify they pass**

```bash
docker compose run --rm app bin/rails test test/models
```

Expected: all green.

**Step 7: Commit**

```bash
git add db app/models test/models
git commit -m "Add Epic, Issue, SyncRun, Presence, BoardSnapshot models and schema"
```

---

## Task 5: Authentication (OmniAuth + allow-list)

**Files:**
- Create: `config/initializers/omniauth.rb`
- Create: `app/controllers/sessions_controller.rb`
- Modify: `app/controllers/application_controller.rb`
- Modify: `config/routes.rb`
- Create: `app/views/sessions/new.html.erb`
- Create: `test/controllers/sessions_controller_test.rb`
- Create: `test/test_helper.rb` additions for OmniAuth mock

**Step 1: Write failing controller test**

`test/controllers/sessions_controller_test.rb`:

```ruby
require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  test "callback signs in user with allowed domain" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "1",
      info: { email: "alice@example.com", name: "Alice" }
    )
    get "/auth/google_oauth2/callback"
    assert_redirected_to root_path
    follow_redirect!
    # session is set; we'll smoke-test that the board renders for authed
    # users in BoardControllerTest later. Here just check the redirect.
  end

  test "callback rejects unallowed domain" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "2",
      info: { email: "mallory@evil.com", name: "Mallory" }
    )
    get "/auth/google_oauth2/callback"
    assert_redirected_to "/login"
    follow_redirect!
    assert_select "body", /not authorized/i
  end

  test "logout clears session" do
    delete "/logout"
    assert_redirected_to "/login"
  end
end
```

Add to `test/test_helper.rb` (above the `class ActiveSupport::TestCase`):

```ruby
ENV["GOOGLE_CLIENT_ID"] ||= "test-id"
ENV["GOOGLE_CLIENT_SECRET"] ||= "test-secret"
ENV["JIRA_BASE_URL"] ||= "https://example.atlassian.net"
ENV["JIRA_EMAIL"] ||= "jira@example.com"
ENV["JIRA_API_TOKEN"] ||= "test-token"
```

**Step 2: Run the test to verify it fails**

```bash
docker compose run --rm app bin/rails test test/controllers/sessions_controller_test.rb
```

Expected: failure due to missing routes/controller.

**Step 3: Configure OmniAuth**

`config/initializers/omniauth.rb`:

```ruby
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           PGBOARD_CONFIG.auth.google_client_id,
           PGBOARD_CONFIG.auth.google_client_secret,
           name: "google_oauth2"
end

OmniAuth.config.allowed_request_methods = [:post, :get]
OmniAuth.config.silence_get_warning     = true
```

**Step 4: Add routes**

Edit `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  root "board#show"
  get  "/login",  to: "sessions#new"
  get  "/auth/:provider/callback", to: "sessions#create"
  get  "/auth/failure",            to: "sessions#failure"
  delete "/logout", to: "sessions#destroy"
end
```

**Step 5: Implement `SessionsController`**

`app/controllers/sessions_controller.rb`:

```ruby
class SessionsController < ApplicationController
  skip_before_action :require_login,   only: %i[new create failure]
  skip_before_action :touch_presence,  only: %i[new create failure]

  def new
  end

  def create
    info  = request.env["omniauth.auth"].info
    email = info.email.to_s.downcase
    if allowed?(email)
      session[:user_email] = email
      session[:user_name]  = info.name
      redirect_to root_path
    else
      redirect_to "/login", alert: "Not authorized for #{email}"
    end
  end

  def failure
    redirect_to "/login", alert: "Sign-in failed"
  end

  def destroy
    reset_session
    redirect_to "/login"
  end

  private

  def allowed?(email)
    return false if email.blank?
    domain = email.split("@", 2).last
    PGBOARD_CONFIG.auth.allowed_emails.include?(email) ||
      PGBOARD_CONFIG.auth.allowed_domains.include?(domain)
  end
end
```

**Step 6: Update `ApplicationController`**

`app/controllers/application_controller.rb`:

```ruby
class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :require_login
  before_action :touch_presence

  helper_method :current_user_email

  private

  def require_login
    redirect_to "/login" unless session[:user_email]
  end

  def touch_presence
    Presence.touch_now!
  end

  def current_user_email
    session[:user_email]
  end
end
```

**Step 7: Add a minimal login view**

`app/views/sessions/new.html.erb`:

```erb
<div class="min-h-screen flex items-center justify-center bg-slate-100">
  <div class="p-8 bg-white rounded shadow text-center">
    <h1 class="text-xl font-semibold mb-4">pgboard</h1>
    <% if flash[:alert] %>
      <p class="text-red-600 mb-4"><%= flash[:alert] %></p>
    <% end %>
    <%= button_to "Sign in with Google", "/auth/google_oauth2",
                  method: :post, class: "px-4 py-2 bg-blue-600 text-white rounded" %>
  </div>
</div>
```

**Step 8: Run the test to verify it passes**

```bash
docker compose run --rm app bin/rails test test/controllers/sessions_controller_test.rb
```

Expected: 3 runs, 0 failures. (You may need to add `BoardController#show` as
a placeholder for the redirect to land — if so, add a trivial controller now;
we'll flesh it out in Task 9.)

If a placeholder is needed, create
`app/controllers/board_controller.rb`:

```ruby
class BoardController < ApplicationController
  def show
    render plain: "ok"
  end
end
```

…and re-run the test.

**Step 9: Commit**

```bash
git add -A
git commit -m "Add Google OAuth login with domain allow-list and SessionsController"
```

---

## Task 6: `JiraClient` facade

**Files:**
- Create: `app/services/jira_client.rb`
- Create: `test/services/jira_client_test.rb`

**Step 1: Write the failing test (HTTP stubbed at WebMock)**

`test/services/jira_client_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraClientTest < ActiveSupport::TestCase
  setup do
    WebMock.disable_net_connect!
  end

  test "search returns issues matching JQL" do
    body = {
      "issues" => [
        { "key" => "PG-1", "fields" => { "summary" => "Foo" } }
      ],
      "total" => 1,
      "startAt" => 0,
      "maxResults" => 50
    }.to_json

    stub_request(:get, %r{/rest/api/2/search})
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })

    client = JiraClient.new
    issues = client.search_all('project = PG')
    assert_equal "PG-1", issues.first.key
  end
end
```

**Step 2: Run the test to verify it fails**

```bash
docker compose run --rm app bin/rails test test/services/jira_client_test.rb
```

Expected: `NameError: uninitialized constant JiraClient`.

**Step 3: Implement the facade**

`app/services/jira_client.rb`:

```ruby
require "jira-ruby"

class JiraClient
  PAGE_SIZE = 50

  def initialize(cfg: PGBOARD_CONFIG.jira)
    @client = JIRA::Client.new(
      username:     cfg.email,
      password:     cfg.api_token,
      site:         cfg.base_url,
      context_path: "",
      auth_type:    :basic
    )
  end

  def search_all(jql, fields: nil)
    results = []
    start_at = 0
    loop do
      page = @client.Issue.jql(jql,
                               start_at: start_at,
                               max_results: PAGE_SIZE,
                               fields: fields)
      results.concat(page)
      break if page.size < PAGE_SIZE
      start_at += PAGE_SIZE
    end
    results
  end
end
```

**Step 4: Run the test to verify it passes**

```bash
docker compose run --rm app bin/rails test test/services/jira_client_test.rb
```

Expected: 1 run, 0 failures.

If `jira-ruby` adds custom path prefixes that cause the WebMock matcher to
miss, broaden the matcher to `%r{/search}` or inspect with `WebMock`'s
disabled-error output. Trust `jira-ruby` for the actual REST shape.

**Step 5: Commit**

```bash
git add app/services/jira_client.rb test/services/jira_client_test.rb
git commit -m "Add JiraClient facade with paginated search"
```

---

## Task 7: `StalenessCalculator`

**Files:**
- Create: `app/services/staleness_calculator.rb`
- Create: `test/services/staleness_calculator_test.rb`

**Step 1: Write the failing test**

`test/services/staleness_calculator_test.rb`:

```ruby
require "test_helper"

class StalenessCalculatorTest < ActiveSupport::TestCase
  def calc(now: Time.utc(2026, 6, 9, 12, 0, 0),
           somewhat: 7, really: 21,
           ignore_for_new: true)
    StalenessCalculator.new(now: now,
                            somewhat_days: somewhat,
                            really_days: really,
                            ignore_for_new: ignore_for_new)
  end

  test "fresh when transitioned recently" do
    assert_equal :fresh,
                 calc.bucket(transitioned_at: Time.utc(2026, 6, 5),
                             display_status: "in_progress")
  end

  test "somewhat when between thresholds" do
    assert_equal :somewhat,
                 calc.bucket(transitioned_at: Time.utc(2026, 5, 25),
                             display_status: "in_progress")
  end

  test "really when older than really_days" do
    assert_equal :really,
                 calc.bucket(transitioned_at: Time.utc(2026, 5, 1),
                             display_status: "in_progress")
  end

  test "new issues skip staleness when ignore_for_new is true" do
    assert_equal :fresh,
                 calc.bucket(transitioned_at: Time.utc(2024, 1, 1),
                             display_status: "new")
  end
end
```

**Step 2: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/services/staleness_calculator_test.rb
```

Expected: `NameError`.

**Step 3: Implement**

`app/services/staleness_calculator.rb`:

```ruby
class StalenessCalculator
  def initialize(now:, somewhat_days:, really_days:, ignore_for_new: true,
                 new_display_statuses: ["new"])
    @now = now
    @somewhat = somewhat_days.days
    @really   = really_days.days
    @ignore_for_new = ignore_for_new
    @new_statuses = new_display_statuses
  end

  def bucket(transitioned_at:, display_status:)
    return :fresh if @ignore_for_new && @new_statuses.include?(display_status)
    age = @now - transitioned_at
    return :really   if age >= @really
    return :somewhat if age >= @somewhat
    :fresh
  end
end
```

**Step 4: Run to verify it passes**

```bash
docker compose run --rm app bin/rails test test/services/staleness_calculator_test.rb
```

Expected: 4 runs, 0 failures.

**Step 5: Commit**

```bash
git add app/services/staleness_calculator.rb test/services/staleness_calculator_test.rb
git commit -m "Add StalenessCalculator with fresh/somewhat/really buckets"
```

---

## Task 8: `BoardPresenter`

**Files:**
- Create: `app/services/board_presenter.rb`
- Create: `test/services/board_presenter_test.rb`
- Create: `test/fixtures/epics.yml`
- Create: `test/fixtures/issues.yml`

**Step 1: Write fixtures**

`test/fixtures/epics.yml`:

```yaml
priority_one:
  jira_key: "PG-1"
  name: "First Priority"
  priority: 1
  jira_status: "In Progress"

priority_two:
  jira_key: "PG-2"
  name: "Second Priority"
  priority: 2
  jira_status: "In Progress"

removed_one:
  jira_key: "PG-9"
  name: "Removed"
  priority: 99
  jira_status: "Done"
  removed_at: <%= Time.current.iso8601 %>
```

`test/fixtures/issues.yml`:

```yaml
fresh_in_progress:
  jira_key: "PG-10"
  epic: priority_one
  issue_type: "Task"
  summary: "Fresh task"
  jira_status: "In Progress"
  status_changed_at_jira: <%= 1.day.ago.iso8601 %>
  created_at_jira: <%= 5.days.ago.iso8601 %>

stale_in_review:
  jira_key: "PG-11"
  epic: priority_one
  issue_type: "Task"
  summary: "Stale review"
  jira_status: "In Review"
  status_changed_at_jira: <%= 30.days.ago.iso8601 %>
  created_at_jira: <%= 60.days.ago.iso8601 %>

new_one:
  jira_key: "PG-12"
  epic: priority_one
  issue_type: "Task"
  summary: "New thing"
  jira_status: "To Do"
  status_changed_at_jira:
  created_at_jira: <%= 1.day.ago.iso8601 %>

done_one:
  jira_key: "PG-13"
  epic: priority_one
  issue_type: "Task"
  summary: "Done thing"
  jira_status: "Done"
  status_changed_at_jira: <%= 3.days.ago.iso8601 %>
  created_at_jira: <%= 14.days.ago.iso8601 %>

unmapped_status:
  jira_key: "PG-14"
  epic: priority_two
  issue_type: "Task"
  summary: "Unmapped"
  jira_status: "Banana"
  status_changed_at_jira: <%= 2.days.ago.iso8601 %>
  created_at_jira: <%= 5.days.ago.iso8601 %>
```

**Step 2: Write the failing test**

`test/services/board_presenter_test.rb`:

```ruby
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
```

**Step 3: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/services/board_presenter_test.rb
```

Expected: `NameError: uninitialized constant BoardPresenter`.

**Step 4: Implement**

`app/services/board_presenter.rb`:

```ruby
class BoardPresenter
  Warning = Struct.new(:issue_key, :status, :reason)

  IssuePresenter = Struct.new(:issue, :display_status, :staleness) do
    def jira_key       = issue.jira_key
    def summary        = issue.summary
    def assignee       = issue.assignee_username
    def jira_status    = issue.jira_status
    def transitioned_at = issue.status_changed_at_jira || issue.created_at_jira
  end

  Column = Struct.new(:epic, :new_issues, :middle_groups, :done_issues) do
    def all_issues
      new_issues + middle_groups.values.flatten + done_issues
    end
  end

  def initialize(epics:, status_map:, new_statuses:, done_statuses:, staleness:)
    @epics = epics
    @status_map = status_map
    @new_statuses = new_statuses
    @done_statuses = done_statuses
    @staleness = staleness
    @warnings = []
  end

  def columns
    @columns ||= @epics.map { |e| build_column(e) }
  end

  def warnings
    columns # force build
    @warnings
  end

  private

  def build_column(epic)
    presented = epic.issues.select { |i| i.removed_at.nil? }.map { |i| present(i, epic) }
    sorted = presented.sort_by { |p| p.transitioned_at || Time.at(0) }

    new_group  = sorted.select { |p| @new_statuses.include?(p.display_status) }
    done_group = sorted.select { |p| @done_statuses.include?(p.display_status) }
    middle     = sorted - new_group - done_group
    middle_groups = middle.group_by(&:display_status)

    Column.new(epic, new_group, middle_groups, done_group)
  end

  def present(issue, epic)
    display = @status_map[issue.jira_status]
    if display.nil?
      @warnings << Warning.new(issue.jira_key, issue.jira_status, "unmapped")
      display = "unknown"
    end
    bucket = @staleness.bucket(
      transitioned_at: issue.status_changed_at_jira || issue.created_at_jira,
      display_status: display
    )
    IssuePresenter.new(issue, display, bucket)
  end
end
```

**Step 5: Run to verify it passes**

```bash
docker compose run --rm app bin/rails test test/services/board_presenter_test.rb
```

Expected: 4 runs, 0 failures.

**Step 6: Commit**

```bash
git add app/services/board_presenter.rb test/services/board_presenter_test.rb test/fixtures
git commit -m "Add BoardPresenter with column ordering, staleness, warnings"
```

---

## Task 9: `BoardController` + views

**Files:**
- Modify: `app/controllers/board_controller.rb`
- Create: `app/views/board/show.html.erb`
- Create: `app/views/board/_column.html.erb`
- Create: `app/views/board/_postit.html.erb`
- Create: `app/views/board/_warning_tray.html.erb`
- Create: `app/views/board/_stale_banner.html.erb`
- Create: `app/views/layouts/application.html.erb` (modify; Tailwind already wired)
- Create: `test/controllers/board_controller_test.rb`

**Step 1: Write the failing test**

`test/controllers/board_controller_test.rb`:

```ruby
require "test_helper"

class BoardControllerTest < ActionDispatch::IntegrationTest
  fixtures :epics, :issues

  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "u1",
      info: { email: "alice@example.com", name: "Alice" }
    )
    get "/auth/google_oauth2/callback"
  end

  test "renders columns for active epics" do
    get root_path
    assert_response :success
    assert_select ".board-column", count: 2
  end

  test "redirects to login when unauthenticated" do
    reset_session
    get root_path
    assert_redirected_to "/login"
  end

  test "renders a postit per active issue" do
    get root_path
    assert_select ".postit"
  end
end
```

Update the test_helper to allow `alice@example.com` (env defaults handle the
config). Add to `test/test_helper.rb` (above the test classes):

```ruby
# Ensure pgboard.yml has the test domain
Pgboard::Config.singleton_class.class_eval do
  alias_method :original_load_from_path, :load_from_path
  def load_from_path(_path)
    load_from_string(<<~YAML)
      jira:
        base_url_env: JIRA_BASE_URL
        email_env: JIRA_EMAIL
        api_token_env: JIRA_API_TOKEN
      auth:
        allowed_domains: ["example.com"]
        allowed_emails: []
        google_client_id_env: GOOGLE_CLIENT_ID
        google_client_secret_env: GOOGLE_CLIENT_SECRET
      polling:
        tick_seconds: 60
        active_window_minutes: 5
        idle_interval_minutes: 60
      board:
        epic_query: 'project = PG'
        users: []
        status_map:
          "To Do": "new"
          "In Progress": "in_progress"
          "In Review": "review"
          "Done": "done"
        new_statuses: ["new"]
        done_statuses: ["done"]
        staleness:
          somewhat_days: 7
          really_days: 21
        ignore_staleness_for_new_issues: true
    YAML
  end
end
PGBOARD_CONFIG = Pgboard::Config.load_from_string(...) # re-init not needed; initializer ran with this stub
```

Note: This shim is one approach. A cleaner alternative is to write
`config/pgboard.yml` as a test-only fixture in CI and rely on the initializer.
Choose whichever fits your codebase taste; this plan uses the shim for
simplicity.

**Step 2: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/controllers/board_controller_test.rb
```

Expected: failure (no view, no rendering pipeline yet).

**Step 3: Implement `BoardController#show`**

`app/controllers/board_controller.rb`:

```ruby
class BoardController < ApplicationController
  def show
    @presenter = BoardPresenter.new(
      epics: Epic.active.ordered.includes(:issues),
      status_map: PGBOARD_CONFIG.board.status_map,
      new_statuses: PGBOARD_CONFIG.board.new_statuses,
      done_statuses: PGBOARD_CONFIG.board.done_statuses,
      staleness: StalenessCalculator.new(
        now: Time.current,
        somewhat_days: PGBOARD_CONFIG.board.staleness.somewhat_days,
        really_days: PGBOARD_CONFIG.board.staleness.really_days,
        ignore_for_new: PGBOARD_CONFIG.board.ignore_staleness_for_new_issues,
        new_display_statuses: PGBOARD_CONFIG.board.new_statuses
      )
    )
    @last_sync = SyncRun.ok.most_recent.first
  end
end
```

**Step 4: Write views**

`app/views/board/show.html.erb`:

```erb
<%= turbo_stream_from "board" %>

<header class="flex items-center justify-between p-4 bg-slate-800 text-white">
  <h1 class="text-lg font-semibold">pgboard</h1>
  <div class="flex items-center gap-4">
    <%= render "board/stale_banner", last_sync: @last_sync %>
    <%= render "board/warning_tray", warnings: @presenter.warnings %>
    <span class="text-sm"><%= current_user_email %></span>
    <%= button_to "Logout", "/logout", method: :delete,
                  class: "text-sm underline" %>
  </div>
</header>

<main class="p-4 overflow-x-auto" data-controller="filters" id="board-root">
  <div class="flex gap-4">
    <% @presenter.columns.each do |col| %>
      <%= render "board/column", column: col %>
    <% end %>
  </div>
</main>
```

`app/views/board/_column.html.erb`:

```erb
<section class="board-column min-w-[280px] w-72 bg-slate-100 rounded p-2"
         data-epic-key="<%= column.epic.jira_key %>">
  <h2 class="font-semibold text-slate-700 mb-2">
    <%= column.epic.name %>
    <span class="text-xs text-slate-500">(<%= column.epic.jira_key %>)</span>
  </h2>

  <% unless column.new_issues.empty? %>
    <details class="mb-2">
      <summary class="cursor-pointer text-sm text-slate-600">
        New (<%= column.new_issues.size %>)
      </summary>
      <% column.new_issues.each do |p| %>
        <%= render "board/postit", p: p %>
      <% end %>
    </details>
  <% end %>

  <% column.middle_groups.each do |display_status, postits| %>
    <h3 class="text-xs uppercase text-slate-500 mt-2"><%= display_status %></h3>
    <% postits.each do |p| %>
      <%= render "board/postit", p: p %>
    <% end %>
  <% end %>

  <% unless column.done_issues.empty? %>
    <details class="mt-2">
      <summary class="cursor-pointer text-sm text-slate-600">
        Done (<%= column.done_issues.size %>)
      </summary>
      <% column.done_issues.each do |p| %>
        <%= render "board/postit", p: p %>
      <% end %>
    </details>
  <% end %>
</section>
```

`app/views/board/_postit.html.erb`:

```erb
<% color = { fresh: "bg-white", somewhat: "bg-yellow-100", really: "bg-red-100" }[p.staleness] %>
<article class="postit <%= color %> rounded shadow-sm p-2 my-1 text-sm"
         data-jira-key="<%= p.jira_key %>"
         data-display-status="<%= p.display_status %>"
         data-assignee="<%= p.assignee %>">
  <a href="<%= jira_url(p.jira_key) %>" target="_blank" class="font-medium">
    <%= p.jira_key %>
  </a>
  <p class="text-slate-700"><%= p.summary %></p>
  <p class="text-xs text-slate-500"><%= p.assignee.presence || "Unassigned" %></p>
</article>
```

`app/views/board/_stale_banner.html.erb`:

```erb
<% if last_sync.nil? %>
  <span class="text-xs text-yellow-300" title="No sync yet">No sync yet</span>
<% else %>
  <% age_min = ((Time.current - last_sync.finished_at) / 60).to_i %>
  <% level = age_min > 30 ? :red : age_min > 5 ? :yellow : :green %>
  <span class="text-xs"
        title="Last sync: <%= last_sync.finished_at.iso8601 %> (<%= age_min %> min ago)">
    <% case level %>
    <% when :green %>
      <span class="text-green-400">●</span>
    <% when :yellow %>
      <span class="text-yellow-300">▲</span>
    <% else %>
      <span class="text-red-400">JIRA sync stalled (<%= age_min %> min)</span>
    <% end %>
  </span>
<% end %>
```

`app/views/board/_warning_tray.html.erb`:

```erb
<% if warnings.any? %>
  <span class="text-xs text-yellow-300"
        title="<%= warnings.map { |w| "#{w.issue_key}: #{w.status}" }.join("\n") %>">
    ⚠ <%= warnings.size %> warnings
  </span>
<% end %>
```

**Step 5: Add `jira_url` helper**

`app/helpers/application_helper.rb`:

```ruby
module ApplicationHelper
  def jira_url(key)
    "#{PGBOARD_CONFIG.jira.base_url}/browse/#{key}"
  end
end
```

**Step 6: Run tests to verify they pass**

```bash
docker compose run --rm app bin/rails test test/controllers/board_controller_test.rb
```

Expected: 3 runs, 0 failures.

**Step 7: Commit**

```bash
git add -A
git commit -m "Add BoardController#show with columns, postits, banners"
```

---

## Task 10: `JiraSync` service

**Files:**
- Create: `app/services/jira_sync.rb`
- Create: `test/services/jira_sync_test.rb`

**Step 1: Write the failing test**

`test/services/jira_sync_test.rb`:

```ruby
require "test_helper"
require "webmock/minitest"

class JiraSyncTest < ActiveSupport::TestCase
  setup do
    WebMock.disable_net_connect!
    Epic.delete_all
    Issue.delete_all
  end

  def stub_search(jql_regex, issues)
    stub_request(:get, %r{/search.*#{Regexp.escape(jql_regex)}.*}i)
      .to_return(
        status: 200,
        body: { "issues" => issues, "total" => issues.size,
                "startAt" => 0, "maxResults" => 50 }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  test "upserts epics and their children" do
    # Be permissive with stubs; jira-ruby's exact URL format is internal.
    stub_request(:get, %r{/search}).to_return do |req|
      body = case req.uri.to_s
             when /labels.*Priority/i
               { "issues" => [
                   { "key" => "PG-1", "fields" => { "summary" => "Epic A",
                                                    "status" => { "name" => "In Progress" },
                                                    "priority" => { "id" => "1" } } }
                 ], "total" => 1, "startAt" => 0, "maxResults" => 50 }
             when /parent\s*=\s*PG-1/i
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
```

**Step 2: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/services/jira_sync_test.rb
```

Expected: `NameError`.

**Step 3: Implement**

`app/services/jira_sync.rb`:

```ruby
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
      assignee_username: ji.fields.dig("assignee", "name"),
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
```

**Step 4: Create the morph partial**

`app/views/board/_board_morph.html.erb`:

```erb
<turbo-stream action="morph" target="board-root">
  <template>
    <div class="flex gap-4">
      <% presenter.columns.each do |col| %>
        <%= render "board/column", column: col %>
      <% end %>
    </div>
  </template>
</turbo-stream>
```

**Step 5: Run tests to verify they pass**

```bash
docker compose run --rm app bin/rails test test/services/jira_sync_test.rb
```

Expected: 3 runs, 0 failures.

You may see broadcast warnings in tests because the cable channel isn't wired
in test env — these are noise. To silence, set `config.action_cable.disable_request_forgery_protection = true`
in `config/environments/test.rb` and ensure `Turbo::StreamsChannel` is loaded.

**Step 6: Commit**

```bash
git add -A
git commit -m "Add JiraSync service with upsert, soft-delete, broadcast"
```

---

## Task 11: `JiraSyncJob` (SolidQueue recurring)

**Files:**
- Create: `app/jobs/jira_sync_job.rb`
- Modify: `config/recurring.yml` (SolidQueue recurring config)
- Create: `test/jobs/jira_sync_job_test.rb`

**Step 1: Write the failing test**

`test/jobs/jira_sync_job_test.rb`:

```ruby
require "test_helper"

class JiraSyncJobTest < ActiveSupport::TestCase
  setup do
    Presence.touch_now!  # mark "someone is here right now"
  end

  test "calls JiraSync.run! in active mode" do
    called = false
    JiraSync.stub :new, ->(*_args, **_kw) { OpenStruct.new(run!: SyncRun.create!(started_at: Time.current, ok: true)) } do
      JiraSyncJob.new.perform
      called = true
    end
    assert called
  end

  test "skips sync in idle mode when last successful sync is recent" do
    Presence.singleton.update!(last_seen_at: 1.hour.ago) # idle
    SyncRun.create!(started_at: 5.minutes.ago, finished_at: 5.minutes.ago, ok: true)

    sync_invoked = false
    JiraSync.stub :new, ->(*) { sync_invoked = true; raise "should not call" } do
      JiraSyncJob.new.perform
    end
    assert_not sync_invoked
  end
end
```

**Step 2: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/jobs/jira_sync_job_test.rb
```

Expected: failure.

**Step 3: Implement the job**

`app/jobs/jira_sync_job.rb`:

```ruby
class JiraSyncJob < ApplicationJob
  queue_as :default

  def perform
    return unless should_run?
    JiraSync.new.run!
  end

  private

  def should_run?
    active_window = PGBOARD_CONFIG.polling.active_window_minutes.minutes
    idle_interval = PGBOARD_CONFIG.polling.idle_interval_minutes.minutes

    last_seen = Presence.singleton.last_seen_at
    return true if last_seen && last_seen >= active_window.ago

    last_ok = SyncRun.ok.most_recent.first&.finished_at
    return true if last_ok.nil?
    last_ok < idle_interval.ago
  end
end
```

**Step 4: Wire SolidQueue recurring**

Edit `config/recurring.yml` (created by `rails new` if SolidQueue gem is in):

```yaml
production:
  jira_sync:
    class: JiraSyncJob
    schedule: every 60 seconds

development:
  jira_sync:
    class: JiraSyncJob
    schedule: every 60 seconds
```

Note: in test env we don't want this firing automatically; SolidQueue
recurring jobs are off in test by default. If your `recurring.yml` from
scaffolding doesn't include a `development` block, follow the production
example.

**Step 5: Run tests to verify they pass**

```bash
docker compose run --rm app bin/rails test test/jobs/jira_sync_job_test.rb
```

Expected: 2 runs, 0 failures.

**Step 6: Commit**

```bash
git add -A
git commit -m "Add JiraSyncJob recurring with active/idle cadence"
```

---

## Task 12: `IssuesController` + modal turbo frame

**Files:**
- Create: `app/controllers/issues_controller.rb`
- Create: `app/views/issues/show.html.erb`
- Modify: `app/views/board/_postit.html.erb` (turbo-frame link)
- Modify: `config/routes.rb`
- Create: `test/controllers/issues_controller_test.rb`

**Step 1: Write the failing test**

`test/controllers/issues_controller_test.rb`:

```ruby
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
```

**Step 2: Run to verify it fails**

```bash
docker compose run --rm app bin/rails test test/controllers/issues_controller_test.rb
```

Expected: routing error.

**Step 3: Add route**

Edit `config/routes.rb` and add:

```ruby
get "/issues/:jira_key", to: "issues#show", as: :issue, constraints: { jira_key: /[^\/]+/ }
```

**Step 4: Implement controller**

`app/controllers/issues_controller.rb`:

```ruby
class IssuesController < ApplicationController
  def show
    @issue = Issue.active.find_by(jira_key: params[:jira_key])
    if @issue.nil?
      render plain: "Not found", status: :not_found
      return
    end
    render layout: false
  end
end
```

**Step 5: Add modal view**

`app/views/issues/show.html.erb`:

```erb
<%= turbo_frame_tag "modal" do %>
  <div class="fixed inset-0 bg-black/40 flex items-center justify-center"
       data-controller="modal" data-action="click->modal#closeIfBackdrop">
    <div class="bg-white rounded p-6 max-w-lg w-full">
      <div class="flex items-center justify-between mb-2">
        <a href="<%= jira_url(@issue.jira_key) %>" target="_blank"
           class="font-semibold text-blue-600"><%= @issue.jira_key %></a>
        <a href="#" data-action="click->modal#close" class="text-slate-500">✕</a>
      </div>
      <h2 class="text-lg mb-2"><%= @issue.summary %></h2>
      <dl class="text-sm text-slate-700 space-y-1">
        <div><dt class="inline font-semibold">Status:</dt> <dd class="inline"><%= @issue.jira_status %></dd></div>
        <div><dt class="inline font-semibold">Assignee:</dt> <dd class="inline"><%= @issue.assignee_username || "Unassigned" %></dd></div>
        <div><dt class="inline font-semibold">Type:</dt> <dd class="inline"><%= @issue.issue_type %></dd></div>
        <div><dt class="inline font-semibold">Created:</dt> <dd class="inline"><%= @issue.created_at_jira&.iso8601 %></dd></div>
        <div><dt class="inline font-semibold">Status changed:</dt> <dd class="inline"><%= @issue.status_changed_at_jira&.iso8601 %></dd></div>
      </dl>
    </div>
  </div>
<% end %>
```

**Step 6: Modify postit to open the modal**

Edit `app/views/board/_postit.html.erb` — wrap the existing content in a
turbo-frame link. Replace the file with:

```erb
<% color = { fresh: "bg-white", somewhat: "bg-yellow-100", really: "bg-red-100" }[p.staleness] %>
<%= link_to issue_path(p.jira_key),
            data: { turbo_frame: "modal" },
            class: "block postit #{color} rounded shadow-sm p-2 my-1 text-sm" do %>
  <span class="font-medium"><%= p.jira_key %></span>
  <p class="text-slate-700"><%= p.summary %></p>
  <p class="text-xs text-slate-500"><%= p.assignee.presence || "Unassigned" %></p>
<% end %>
```

Add an empty `modal` frame to the layout so navigation lands there.
Edit `app/views/layouts/application.html.erb` and insert just above `</body>`:

```erb
<%= turbo_frame_tag "modal" %>
```

**Step 7: Run tests**

```bash
docker compose run --rm app bin/rails test test/controllers/issues_controller_test.rb
```

Expected: 2 runs, 0 failures.

**Step 8: Commit**

```bash
git add -A
git commit -m "Add IssuesController modal turbo-frame and postit click target"
```

---

## Task 13: Stimulus controllers (filters, theme, modal)

**Files:**
- Create: `app/javascript/controllers/filters_controller.js`
- Create: `app/javascript/controllers/theme_controller.js`
- Create: `app/javascript/controllers/modal_controller.js`
- Modify: `app/javascript/controllers/index.js`

**Step 1: Implement `filters_controller.js`**

`app/javascript/controllers/filters_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    assignees: Array,
    statuses: Array,
    freshOnly: Boolean,
    staleOnly: Boolean
  }

  connect() {
    this.loadFromHash()
    this.apply()
  }

  toggleAssignee(event) {
    const name = event.params.name
    this.assigneesValue = this.toggle(this.assigneesValue, name)
    this.persist()
    this.apply()
  }

  toggleStatus(event) {
    const name = event.params.name
    this.statusesValue = this.toggle(this.statusesValue, name)
    this.persist()
    this.apply()
  }

  toggleFreshOnly() {
    this.freshOnlyValue = !this.freshOnlyValue
    this.staleOnlyValue = false
    this.persist()
    this.apply()
  }

  toggleStaleOnly() {
    this.staleOnlyValue = !this.staleOnlyValue
    this.freshOnlyValue = false
    this.persist()
    this.apply()
  }

  toggle(arr, name) {
    return arr.includes(name) ? arr.filter(x => x !== name) : [...arr, name]
  }

  apply() {
    const postits = this.element.querySelectorAll(".postit")
    postits.forEach(p => {
      const assignee = p.dataset.assignee
      const status   = p.dataset.displayStatus
      const stale    = p.classList.contains("bg-red-100") || p.classList.contains("bg-yellow-100")
      const fresh    = !stale

      const passAssignee = this.assigneesValue.length === 0 || this.assigneesValue.includes(assignee)
      const passStatus   = this.statusesValue.length   === 0 || this.statusesValue.includes(status)
      const passFresh    = !this.freshOnlyValue || fresh
      const passStale    = !this.staleOnlyValue || stale

      p.classList.toggle("hidden", !(passAssignee && passStatus && passFresh && passStale))
    })
  }

  persist() {
    const state = {
      a: this.assigneesValue,
      s: this.statusesValue,
      f: this.freshOnlyValue,
      x: this.staleOnlyValue
    }
    location.hash = encodeURIComponent(JSON.stringify(state))
  }

  loadFromHash() {
    if (!location.hash) return
    try {
      const state = JSON.parse(decodeURIComponent(location.hash.slice(1)))
      this.assigneesValue = state.a || []
      this.statusesValue  = state.s || []
      this.freshOnlyValue = !!state.f
      this.staleOnlyValue = !!state.x
    } catch {}
  }
}
```

**Step 2: Implement `theme_controller.js`**

`app/javascript/controllers/theme_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    const saved = localStorage.getItem("pgboard-theme")
    if (saved) document.documentElement.dataset.theme = saved
  }

  toggle() {
    const cur = document.documentElement.dataset.theme === "dark" ? "light" : "dark"
    document.documentElement.dataset.theme = cur
    localStorage.setItem("pgboard-theme", cur)
  }
}
```

Add `data-theme` styling via Tailwind dark variant: ensure `tailwind.config.js`
(generated by tailwindcss-rails) uses `darkMode: ["selector", "[data-theme='dark']"]`.

**Step 3: Implement `modal_controller.js`**

`app/javascript/controllers/modal_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  closeIfBackdrop(event) {
    if (event.target === this.element) this.close()
  }

  close(event) {
    event?.preventDefault()
    const frame = document.querySelector("turbo-frame#modal")
    if (frame) frame.innerHTML = ""
  }
}
```

**Step 4: Verify Stimulus picks them up**

`app/javascript/controllers/index.js` is wired automatically by Rails 8's
importmap+stimulus integration via `eagerLoadControllersFrom`. No edit needed
if you used the generator. If you didn't, ensure:

```javascript
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)
```

**Step 5: Smoke test in the browser**

```bash
task dev
```

Visit http://localhost:3000, sign in (you can fake the OmniAuth callback in
dev by visiting `/auth/google_oauth2` with `OmniAuth.config.test_mode = true`
set conditionally — or temporarily make `BoardController#show` accessible).

For now, just verify the JS bundle loads without console errors via the
network tab.

**Step 6: Commit**

```bash
git add -A
git commit -m "Add filters/theme/modal Stimulus controllers"
```

---

## Task 14: System tests (Capybara + Selenium)

**Files:**
- Modify: `test/application_system_test_case.rb`
- Create: `test/system/board_test.rb`
- Create: `test/system/modal_test.rb`
- Create: `test/system/morph_test.rb`

**Step 1: Configure Capybara to use the `chromium` service**

Edit `test/application_system_test_case.rb`:

```ruby
require "test_helper"
require "capybara/rails"
require "selenium/webdriver"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 900] do |options|
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  Capybara.server_host = "0.0.0.0"
  Capybara.app_host = "http://app:3000" # only relevant in fully-remote mode
end
```

When running tests via `docker compose run`, the selenium webdriver connects
to `http://chromium:4444/wd/hub`. Set:

```ruby
driven_by :selenium, using: :headless_chrome, screen_size: [1400, 900],
          options: { browser: :remote, url: "http://chromium:4444/wd/hub" }
```

Pick whichever variant the chromium image expects; consult its docs.

**Step 2: Write `board_test.rb`**

`test/system/board_test.rb`:

```ruby
require "application_system_test_case"

class BoardSystemTest < ApplicationSystemTestCase
  fixtures :epics, :issues

  setup do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "u1",
      info: { email: "alice@example.com", name: "Alice" }
    )
  end

  test "logged-in user sees columns and postits" do
    visit "/auth/google_oauth2/callback"
    visit "/"
    assert_selector ".board-column", minimum: 2
    assert_selector ".postit", minimum: 4
  end
end
```

**Step 3: Write `modal_test.rb`**

`test/system/modal_test.rb`:

```ruby
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
    find(".postit", text: "Fresh task").click
    assert_selector "turbo-frame#modal", text: "Fresh task"
  end
end
```

**Step 4: Write `morph_test.rb`**

`test/system/morph_test.rb`:

```ruby
require "application_system_test_case"

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
    find(".postit", text: "Fresh task").click
    assert_selector "turbo-frame#modal", text: "Fresh task"

    # Simulate a server-side morph broadcast
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

    # Wait for cable to deliver
    sleep 0.5
    assert_selector "turbo-frame#modal", text: "Fresh task"
  end
end
```

**Step 5: Run system tests**

```bash
docker compose run --rm app bin/rails test:system
```

Expected: 3 runs, 0 failures. (You'll iterate; selenium remote configuration
is finicky.)

**Step 6: Commit**

```bash
git add -A
git commit -m "Add system tests for board render, modal open, morph preserves modal"
```

---

## Task 15: Production Dockerfile + compose + Caddy

**Files:**
- Create: `Dockerfile` (prod)
- Create: `docker-compose.prod.yml`
- Create: `caddy/Caddyfile`
- Create: `.env.example`

**Step 1: Write the production `Dockerfile`**

Note: `rails new` may have already written one; review and adapt. The Rails 8
default `Dockerfile` is generally suitable. Tweak to ensure SolidQueue runs
in-process:

```dockerfile
ENV SOLID_QUEUE_IN_PUMA=true
```

Add to the existing `Dockerfile` (or rewrite if it's missing).

**Step 2: Write `docker-compose.prod.yml`**

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    expose:
      - "3000"
    env_file:
      - .env
    volumes:
      - ./storage:/rails/storage
    environment:
      RAILS_ENV: production
      SOLID_QUEUE_IN_PUMA: "true"

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
```

**Step 3: Write `caddy/Caddyfile`**

```caddy
pgboard.example.com {
  reverse_proxy app:3000
}
```

(Replace the hostname when you wire DNS to the Hetzner box.)

**Step 4: Write `.env.example`**

```env
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=jira@example.com
JIRA_API_TOKEN=changeme
GOOGLE_CLIENT_ID=changeme
GOOGLE_CLIENT_SECRET=changeme
SECRET_KEY_BASE=changeme
RAILS_MASTER_KEY=
```

**Step 5: Verify the production image builds locally**

```bash
docker build -t pgboard-prod .
```

Expected: builds without errors.

**Step 6: Commit**

```bash
git add Dockerfile docker-compose.prod.yml caddy .env.example
git commit -m "Add production Dockerfile, compose, and Caddy reverse proxy"
```

---

## Task 16: Taskfile redeploy + final polish

**Files:**
- Modify: `Taskfile.yml`
- Create: `README.md` (short runbook)

**Step 1: Extend `Taskfile.yml` with `redeploy`**

Append to `Taskfile.yml`:

```yaml
  redeploy:
    desc: "Rebuild and restart the prod stack (run on the Hetzner box after git pull)"
    cmds:
      - docker compose -f docker-compose.prod.yml up -d --build
      - docker compose -f docker-compose.prod.yml exec app bin/rails db:migrate

  prod-logs:
    desc: "Tail prod app logs"
    cmds:
      - docker compose -f docker-compose.prod.yml logs -f app
```

**Step 2: Write `README.md`**

`README.md`:

```markdown
# pgboard

Read-only Kanban-style board for our JIRA project. See
[`docs/plans/2026-06-09-pgboard-design.md`](docs/plans/2026-06-09-pgboard-design.md)
for architecture.

## Run locally

```
cp .env.example .env       # fill in secrets
cp config/pgboard.example.yml config/pgboard.yml
task dev                   # http://localhost:3000
```

## Tests

```
task test
```

## Deploy

On the Hetzner VM:
```
ssh hetzner
cd /srv/pgboard
git pull
task redeploy
```
```

**Step 3: Commit**

```bash
git add Taskfile.yml README.md
git commit -m "Add redeploy task and runbook README"
```

---

## Final verification

```bash
task test                    # all green
task dev                     # http://localhost:3000, OAuth login, see board
docker compose run --rm app bin/rails about
```

Expected: tests pass, the board renders, modal opens on click, morph keeps
the modal open.

## Out-of-scope items deferred

- Pulling `status_changed_at_jira` from JIRA's changelog (currently set when
  status differs from DB row, which is good enough for the common case).
- Backups (spec says skip).
- Mobile layout (revisit later per spec).
- Per-issue-type status map (current flat map is sufficient given the user's
  choice during brainstorming).

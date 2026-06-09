module ApplicationHelper
  def jira_url(key)
    "#{PGBOARD_CONFIG.jira.base_url}/browse/#{key}"
  end
end

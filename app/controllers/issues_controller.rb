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

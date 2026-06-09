Rails.application.routes.draw do
  root "board#show"
  get  "/login",  to: "sessions#new"
  get  "/auth/:provider/callback", to: "sessions#create"
  get  "/auth/failure",            to: "sessions#failure"
  delete "/logout", to: "sessions#destroy"
  get "/issues/:jira_key", to: "issues#show", as: :issue, constraints: { jira_key: /[^\/]+/ }
end

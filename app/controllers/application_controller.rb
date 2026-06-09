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

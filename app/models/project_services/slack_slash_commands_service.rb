class SlackSlashCommandsService < ChatService
  include TriggersHelper

  prop_accessor :token

  def can_test?
    false
  end

  def title
    'Slack Slash Command'
  end

  def description
    "Perform common operations on GitLab in Slack"
  end

  def to_param
    'slack_slash_commands'
  end

  def fields
    [
      { type: 'text', name: 'token', placeholder: '' }
    ]
  end

  def trigger(params)
    return nil unless valid_token?(params[:token])

    user = find_chat_user(params)
    unless user
      url = authorize_chat_name_url(params)
      return Gitlab::ChatCommands::Presenters::Access.new(url).authorize
    end

    Gitlab::ChatCommands::Command.new(project, user, params).execute
  end

  private

  def find_chat_user(params)
    ChatNames::FindUserService.new(self, params).execute
  end

  def authorize_chat_name_url(params)
    ChatNames::AuthorizeUserService.new(self, params).execute
  end
end

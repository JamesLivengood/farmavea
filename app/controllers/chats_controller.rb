# The visitor-facing side of the chat. A conversation is found by the token the
# browser holds, never by anything identifying - see the migration for why.
class ChatsController < ApplicationController
  # A public endpoint that writes rows and pushes a phone notification, so it needs
  # a ceiling. Generous enough that a real conversation never hits it.
  MAX_MESSAGES_PER_WINDOW = 12
  RATE_LIMIT_WINDOW = 10.minutes

  # Returns the conversation's messages, so the page can show the operator's reply
  # when the visitor comes back.
  def show
    conversation = find_conversation
    if conversation.nil?
      render json: { messages: [] }
      return
    end

    render json: {
      token: conversation.token,
      messages: conversation.messages.map { |m| serialize(m) }
    }
  end

  def create
    body = params[:body].to_s.strip
    if body.blank?
      render json: { error: "Escribe un mensaje." }, status: :unprocessable_entity
      return
    end
    if body.length > ChatMessage::MAX_LENGTH
      render json: { error: "El mensaje es demasiado largo." }, status: :unprocessable_entity
      return
    end

    conversation = find_conversation || ChatConversation.new
    if rate_limited?(conversation)
      render json: { error: "Has enviado varios mensajes. Espera unos minutos." }, status: :too_many_requests
      return
    end

    # Only stored when the visitor actually typed one; never inferred.
    email = params[:email].to_s.strip
    conversation.visitor_email = email if email.present?
    conversation.save!

    message = conversation.messages.create!(author: "visitor", body: body)
    NotifyOperatorOfChatMessageJob.perform_later(message.id)

    render json: {
      token: conversation.token,
      message: serialize(message)
    }, status: :created
  end

  private

  def find_conversation
    token = params[:token].to_s
    return nil if token.blank?

    ChatConversation.find_by(token: token)
  end

  def rate_limited?(conversation)
    return false if conversation.new_record?

    conversation.messages.from_visitors
                .where(created_at: RATE_LIMIT_WINDOW.ago..)
                .count >= MAX_MESSAGES_PER_WINDOW
  end

  def serialize(message)
    {
      author: message.author,
      body: message.body,
      at: message.created_at.iso8601
    }
  end
end

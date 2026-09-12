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
      # Presence is still useful with no conversation: a first-time visitor needs to
      # know whether anyone is there before deciding to type.
      render json: { messages: [], online: ChatStatus.online? }
      return
    end

    render json: {
      token: conversation.token,
      online: ChatStatus.online?,
      # So a returning visitor who already left details is not asked again.
      contact_given: conversation.visitor_email.present? || conversation.visitor_phone.present?,
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

    # Only stored when the visitor actually typed them; never inferred.
    email = params[:email].to_s.strip
    phone = params[:phone].to_s.strip

    # Offline there is no way to answer someone who leaves no contact details -
    # their message would sit unread and they would never learn why. Enforced here
    # rather than only in the form, since the endpoint is public.
    if requires_contact?(conversation, email, phone)
      render json: {
        error: "Ahora mismo no estamos en línea. Déjanos tu correo o teléfono y te respondemos en cuanto podamos.",
        requires_contact: true
      }, status: :unprocessable_entity
      return
    end

    conversation.visitor_email = email if email.present?
    conversation.visitor_phone = phone if phone.present?

    unless conversation.save
      render json: { error: conversation.errors.full_messages.first || "Revisa tus datos." },
             status: :unprocessable_entity
      return
    end

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

  # Only for a brand-new conversation: once someone has left contact details, or is
  # mid-conversation with an operator who has already replied, demanding them again
  # on every message would be obstructive.
  def requires_contact?(conversation, email, phone)
    return false if ChatStatus.online?
    return false if email.present? || phone.present?

    conversation.visitor_email.blank? && conversation.visitor_phone.blank?
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

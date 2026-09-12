module Admin
  # The operator's inbox. Behind HTTP basic auth because it exposes what visitors
  # asked about their medication - sensitive personal data under the LFPDPPP, and
  # exactly the reason the traffic report is a script rather than a web page.
  class ChatsController < ApplicationController
    http_basic_authenticate_with(
      name: ENV.fetch("ADMIN_USERNAME", "admin"),
      password: ENV.fetch("ADMIN_PASSWORD", nil)
    ) if ENV["ADMIN_PASSWORD"].present?

    before_action :require_configured_credentials

    def index
      @conversations = ChatConversation.recent.limit(100).includes(:messages)
    end

    def show
      @conversation = ChatConversation.find(params[:id])
      @conversation.messages.from_visitors.where(read_at: nil).update_all(read_at: Time.current)
    end

    def reply
      conversation = ChatConversation.find(params[:id])
      body = params[:body].to_s.strip

      if body.blank?
        redirect_to admin_chat_path(conversation), alert: "Escribe una respuesta."
        return
      end

      # The operator writes in English; the visitor reads Spanish. Translate before
      # storing so the visitor sees only their own language - and fall back to the
      # original if translation is unavailable, because a reply in the wrong
      # language beats no reply at all.
      outgoing = if params[:translate] == "1"
        Chat::Translator.to_spanish(body) || body
      else
        body
      end

      conversation.messages.create!(author: "operator", body: outgoing)
      notice = outgoing == body ? "Respuesta enviada." : "Respuesta enviada (traducida al español)."
      redirect_to admin_chat_path(conversation), notice: notice
    end

    private

    # Without a password set, this page would be world-readable. Fail closed rather
    # than silently serving strangers' health questions to anyone who finds the URL.
    def require_configured_credentials
      return if ENV["ADMIN_PASSWORD"].present?

      render plain: "El panel de administración no está configurado (falta ADMIN_PASSWORD).",
             status: :service_unavailable
    end
  end
end

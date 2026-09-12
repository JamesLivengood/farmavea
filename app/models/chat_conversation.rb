# One visitor's thread. Identified only by a random token kept in their browser -
# see the migration for why it is deliberately not tied to who they are.
class ChatConversation < ApplicationRecord
  has_many :messages, -> { order(:created_at) },
           class_name: "ChatMessage", dependent: :destroy, inverse_of: :chat_conversation

  STATUSES = %w[open closed].freeze

  validates :token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  # Optional - a visitor can chat without giving one. Only validated when present.
  validates :visitor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  before_validation :assign_token, on: :create

  scope :recent, -> { order(last_message_at: :desc) }
  scope :with_unread_visitor_messages, lambda {
    where(id: ChatMessage.where(author: "visitor", read_at: nil).select(:chat_conversation_id))
  }

  # Health-adjacent free text should not accumulate indefinitely. Conversations are
  # deleted after this; see CleanUpChatConversationsJob.
  RETENTION = 90.days

  def self.purge_old!
    cutoff = RETENTION.ago
    where(last_message_at: ...cutoff).or(where(last_message_at: nil).where(created_at: ...cutoff))
                                     .destroy_all
  end

  def unread_count
    messages.where(author: "visitor", read_at: nil).count
  end

  private

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(24)
  end
end

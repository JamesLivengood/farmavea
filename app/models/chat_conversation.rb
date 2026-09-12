# One visitor's thread. Identified only by a random token kept in their browser -
# see the migration for why it is deliberately not tied to who they are.
class ChatConversation < ApplicationRecord
  has_many :messages, -> { order(:created_at) },
           class_name: "ChatMessage", dependent: :destroy, inverse_of: :chat_conversation

  STATUSES = %w[open closed].freeze

  validates :token, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  # Optional - a visitor can chat without giving either. Only validated when present.
  validates :visitor_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  # Deliberately loose: Mexican numbers get written +52 443 123 4567, 4431234567,
  # (443) 123-4567 and every variation in between. Rejecting a real number because
  # of its punctuation loses a way to reach someone.
  validates :visitor_phone, length: { in: 8..25 }, allow_blank: true

  # What the operator can actually reach this visitor on, for the notification.
  def contact_line
    parts = []
    parts << visitor_email if visitor_email.present?
    parts << visitor_phone if visitor_phone.present?
    parts.any? ? parts.join(" · ") : "sin contacto"
  end

  before_validation :assign_token, on: :create

  scope :recent, -> { order(last_message_at: :desc) }
  scope :with_unread_visitor_messages, lambda {
    where(id: ChatMessage.where(author: "visitor", read_at: nil).select(:chat_conversation_id))
  }

  # Health-adjacent free text should not accumulate indefinitely. Conversations are
  # deleted after this; see PurgeOldChatConversationsJob.
  #
  # This retention window is the ONLY thing that should ever delete a conversation.
  # Ad-hoc cleanups ("destroy anything from the last 30 minutes") were used to tidy
  # up after testing and silently destroyed real visitor messages that had already
  # been delivered to Telegram - the operator saw notifications for conversations
  # that no longer existed in the inbox. Delete by age only, never by recency.
  RETENTION = 90.days

  def self.purge_old!
    cutoff = RETENTION.ago
    where(last_message_at: ...cutoff).or(where(last_message_at: nil).where(created_at: ...cutoff))
                                     .destroy_all
  end

  def unread_count
    messages.where(author: "visitor", read_at: nil).count
  end

  # A conversation started by an end-to-end check rather than a person. Marked so
  # test traffic can be cleaned up precisely, instead of by "anything recent" -
  # which is how real messages got destroyed alongside test ones.
  TEST_MARKER = "[prueba]".freeze

  def test?
    messages.first&.body.to_s.include?(TEST_MARKER)
  end

  def self.purge_test_conversations!
    joins(:messages).where("chat_messages.body LIKE ?", "%#{TEST_MARKER}%").distinct.destroy_all
  end

  private

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(24)
  end
end

# Whether someone is currently available to answer the chat.
#
# One row, read on every page render and written rarely. Lives in the database
# rather than an env var so the operator can flip it from their phone by sending
# the bot "online" or "offline" - no deploy, no admin login.
class ChatStatus < ApplicationRecord
  # Cheap and frequently read: the widget asks on every page load. Cleared on write.
  CACHE_KEY = "chat_status/online".freeze

  def self.current
    first_or_create!(online: false, changed_at: Time.current)
  end

  def self.online?
    Rails.cache.fetch(CACHE_KEY, expires_in: 1.minute) { current.online? }
  end

  def self.set!(online)
    record = current
    record.update!(online: online, changed_at: Time.current)
    Rails.cache.delete(CACHE_KEY)
    record
  end

  # Recognised in a Telegram message. Kept liberal - the operator is typing this
  # one-handed on a phone, and a status that silently fails to change is worse than
  # one that accepts a few spellings.
  ONLINE_WORDS = %w[online en-linea enlinea disponible activo on].freeze
  OFFLINE_WORDS = %w[offline desconectado ausente fuera off].freeze

  # Returns true, false, or nil when the text is not a status command at all.
  def self.parse_command(text)
    word = text.to_s.strip.downcase.delete_suffix(".")
    return true if ONLINE_WORDS.include?(word)
    return false if OFFLINE_WORDS.include?(word)

    nil
  end
end

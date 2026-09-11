# Minimal stand-ins for the real Anthropic SDK's response shapes - built to expose
# exactly the methods ClaudeMedicationMatcher actually calls (response.content,
# block.type/.input, response.usage.*, response.stop_reason), rather than depending
# on the SDK's real model classes, which would make tests brittle against gem
# version upgrades.
FakeToolUseBlock = Struct.new(:input) do
  def type = :tool_use
end

FakeUsage = Struct.new(:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens, keyword_init: true)

FakeClaudeResponse = Struct.new(:content, :usage, :stop_reason, keyword_init: true) do
  # stop_reason: pass :max_tokens to simulate a response truncated mid-tool-call,
  # which is how a batch silently loses the names Claude never got to.
  def self.with_matches(matches, usage: nil, stop_reason: :end_turn)
    new(
      content: [ FakeToolUseBlock.new({ "matches" => matches }) ],
      usage: usage || FakeUsage.new(input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 0, cache_creation_input_tokens: 100),
      stop_reason: stop_reason
    )
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class ParallelDigestTest < Minitest::Test
  def test_cold_worker_hashing_in_fresh_processes
    engine = File.expand_path("../../Sources/PlayerSpeech/Resources/Engine/srt_voiceover.rb", __dir__)
    code = <<~'RUBY'
      require ARGV.fetch(0)
      # The algorithm must be ready before the first worker reaches its phrase cache.
      abort "SHA-256 was left for threaded autoload" unless Digest.const_defined?(:SHA256, false)
      gate = Queue.new
      threads = 12.times.map do
        Thread.new do
          gate.pop
          100.times do
            hash = Digest::SHA256.hexdigest("abc")
            abort "incorrect hash" unless hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          end
        end
      end
      threads.length.times { gate << true }
      threads.each(&:value)
    RUBY
    5.times do
      output, status = Open3.capture2e(RbConfig.ruby, "-e", code, engine)
      assert status.success?, output
    end
  end
end

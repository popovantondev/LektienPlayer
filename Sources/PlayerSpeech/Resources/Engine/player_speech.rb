#!/usr/bin/ruby
# frozen_string_literal: true

require_relative "srt_voiceover"

# The coordinator and all workers share a process group for bounded cancellation.
Process.setpgrp
$stdout.sync = true

class SileroWorker
  alias_method :initialize_engine, :initialize
end

module CachedSileroSpeech
  def initialize(program_dir, speaker)
    @cache_speaker = speaker
    @engine_arguments = [program_dir, speaker]
  end

  def synthesize(text, output_path)
    key = Digest::SHA256.hexdigest(["speech-v1-v5_5_ru", @cache_speaker, SAMPLE_RATE, text].join("\n"))
    root = ENV.fetch("LEKTIEN_PHRASE_CACHE")
    FileUtils.mkdir_p(root, mode: 0o700)
    cached = File.join(root, "#{key}.wav")
    if File.file?(cached)
      raise VoiceoverError, "Повреждён сохранённый речевой фрагмент" if wav_pcm(cached).empty?
      FileUtils.cp(cached, output_path)
      return
    end
    unless @engine_started
      initialize_engine(*@engine_arguments)
      @engine_started = true
    end
    super
    raise VoiceoverError, "Синтезатор вернул пустой звук" if wav_pcm(output_path).empty?
    # Both paths live inside the same library; link never overwrites finished audio.
    File.open(output_path, "rb") { |file| file.fsync }
    begin
      File.link(output_path, cached)
    rescue Errno::EEXIST
      # Another identical phrase may complete in the same worker pool.
    end
  end
end

SileroWorker.prepend(CachedSileroSpeech)

def find_ffmpeg
  path = ENV.fetch("LEKTIEN_FFMPEG")
  File.executable?(path) ? path : nil
end

exit(run_voiceover(ARGV))

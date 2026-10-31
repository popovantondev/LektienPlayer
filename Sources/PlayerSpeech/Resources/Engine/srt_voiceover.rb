#!/usr/bin/ruby
# frozen_string_literal: true

require "fileutils"
# Load SHA-256 before the worker threads; lazy Digest autoload races on cold phrase caches.
require "digest/sha2"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require_relative "speech_normalizer"

Cue = Struct.new(:number, :start_ms, :end_ms, :text)
Phrase = Struct.new(:first_cue, :last_cue, :start_ms, :end_ms, :text)
SmoothPhrase = Struct.new(:first_cue, :last_cue, :start_ms, :end_ms, :text, :continuation)
SpeechIsland = Struct.new(:phrases, :start_ms, :end_ms, :boundary_after)

SAMPLE_RATE = 24_000
BITS_PER_SAMPLE = 16
CHANNELS = 1

class VoiceoverError < StandardError; end

def voiceover_data_dir(program_dir)
  configured = ENV["SRT_VOICEOVER_DATA_DIR"].to_s.strip
  configured.empty? ? program_dir : File.expand_path(configured)
end

def silero_environment_dir(program_dir)
  configured = ENV["SRT_VOICEOVER_SILERO_DIR"].to_s.strip
  return File.expand_path(configured) unless configured.empty?
  File.join(voiceover_data_dir(program_dir), ".venv-silero")
end

class SileroWorker
  def initialize(program_dir, speaker)
    python = File.join(silero_environment_dir(program_dir), "bin", "python")
    worker = File.join(program_dir, "silero_worker.py")
    raise VoiceoverError, "Silero ещё не установлен: не найден #{python}" unless File.executable?(python)
    raise VoiceoverError, "Не найден помощник Silero: #{worker}" unless File.file?(worker)

    @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
      python, worker, "--speaker", speaker, "--sample-rate", SAMPLE_RATE.to_s
    )
    @stderr_thread = Thread.new do
      @stderr.each_line { |line| warn "Silero: #{line.rstrip}" }
    end
    response = read_response
    raise VoiceoverError, "Silero не запустился: #{response['error']}" unless response["ready"]
  rescue StandardError
    close
    raise
  end

  def synthesize(text, output_path)
    @stdin.puts(JSON.generate({ text: text, output_path: output_path }))
    @stdin.flush
    response = read_response
    unless response["ok"]
      kind = response["error_type"]
      raise VoiceoverError, "Ошибка синтеза Silero#{kind ? " (#{kind})" : ""}: #{response['error']}"
    end
  rescue Errno::EPIPE, IOError => error
    raise VoiceoverError, "Процесс Silero завершился: #{error.message}"
  end

  def close
    @stdin&.close unless @stdin&.closed?
    @wait_thread&.join(3)
    if @wait_thread&.alive?
      Process.kill("TERM", @wait_thread.pid)
      @wait_thread.join(2)
    end
    if @wait_thread&.alive?
      Process.kill("KILL", @wait_thread.pid)
      @wait_thread.join(1)
    end
    @stderr_thread&.join(1)
    @stdout&.close unless @stdout&.closed?
    @stderr&.close unless @stderr&.closed?
    @stderr_thread&.join(1)
  rescue Errno::ESRCH, IOError
    nil
  end

  private

  def read_response
    line = @stdout&.gets
    raise VoiceoverError, "Silero неожиданно завершился" unless line
    JSON.parse(line)
  rescue JSON::ParserError => error
    raise VoiceoverError, "Некорректный ответ Silero: #{error.message}"
  end
end

# Silero is CPU-only on the bundled Russian model.  Three independent workers
# are faster on an M4 than one worker with many Torch threads, while keeping
# memory use reasonable.  Audio is never cached: every job is generated from
# the current text and current selected speaker.
class SileroWorkerPool
  DEFAULT_SIZE = 3

  def initialize(program_dir, speaker, size: DEFAULT_SIZE)
    @workers = []
    @closed = false
    # Start one process first.  On the first ever run it may download the model;
    # the remaining processes then open the completed local copy safely.
    @workers << SileroWorker.new(program_dir, speaker)
    created = []
    errors = []
    startup_mutex = Mutex.new
    threads = Array.new([size - 1, 0].max) do
      Thread.new do
        worker = SileroWorker.new(program_dir, speaker)
        startup_mutex.synchronize { created << worker }
      rescue StandardError => error
        startup_mutex.synchronize { errors << error }
      end
    end
    threads.each(&:join)
    @workers.concat(created)
    raise errors.first unless errors.empty?
  rescue StandardError
    close
    raise
  end

  def synthesize_all(jobs, &progress)
    queue = Queue.new
    jobs.each { |job| queue << job }
    @workers.length.times { queue << nil }
    mutex = Mutex.new
    progress_mutex = Mutex.new
    completed = 0
    errors = []
    abort_requested = false

    threads = @workers.map do |worker|
      Thread.new do
        loop do
          job = queue.pop
          break unless job
          break if mutex.synchronize { abort_requested }
          index, text, output_path = job
          begin
            worker.synthesize(text, output_path)
          rescue StandardError => error
            mutex.synchronize do
              errors << [index, error]
              abort_requested = true
            end
          ensure
            count = mutex.synchronize { completed += 1 }
            progress_mutex.synchronize { progress.call(count, jobs.length) } if progress
          end
        end
      end
    end
    threads.each(&:join)
    unless errors.empty?
      index, error = errors.min_by(&:first)
      raise VoiceoverError, "Фраза #{index + 1}: #{error.message}"
    end
    true
  end

  def synthesize(text, output_path)
    @workers.first.synthesize(text, output_path)
  end

  def close
    return if @closed
    @closed = true
    @workers&.each do |worker|
      worker.close
    rescue StandardError => error
      warn "Не удалось закрыть процесс Silero: #{error.message}"
    end
  end
end

def parse_time(value)
  match = value.match(/\A(\d{2}):(\d{2}):(\d{2}),(\d{3})\z/)
  raise VoiceoverError, "Некорректный таймкод: #{value}" unless match

  hours, minutes, seconds, millis = match.captures.map(&:to_i)
  raise VoiceoverError, "Некорректный таймкод: #{value}" if minutes >= 60 || seconds >= 60
  ((hours * 3600 + minutes * 60 + seconds) * 1000) + millis
end

def parse_srt(path)
  source = File.read(path, encoding: "bom|utf-8").gsub("\r\n", "\n")
  cues = source.strip.split(/\n\s*\n/).map.with_index do |block, index|
    lines = block.lines.map(&:strip)
    if lines.length < 3 || !lines[0].match?(/\A\d+\z/)
      raise VoiceoverError, "Некорректный блок SRT №#{index + 1}"
    end

    timing = lines[1].match(/\A(.+?)\s+-->\s+(.+?)\z/)
    raise VoiceoverError, "Не найден таймкод в блоке №#{index + 1}" unless timing

    Cue.new(
      lines[0].sub(/\A\uFEFF/, "").to_i,
      parse_time(timing[1]),
      parse_time(timing[2]),
      lines[2..-1].join(" ").gsub(/<[^>]+>/, "").gsub(/\s+/, " ").strip
    )
  end.compact

  raise VoiceoverError, "В SRT не найдено ни одной реплики" if cues.empty?
  raise VoiceoverError, "В SRT есть пустые реплики" if cues.any? { |cue| cue.text.empty? }
  raise VoiceoverError, "В SRT повторяются номера реплик" unless cues.map(&:number).uniq.length == cues.length
  raise VoiceoverError, "В SRT есть нулевая или отрицательная длительность" if cues.any? { |cue| cue.end_ms <= cue.start_ms }
  raise VoiceoverError, "В SRT нарушен порядок таймкодов" if cues.each_cons(2).any? { |a, b| b.start_ms < a.start_ms }
  cues.each_cons(2) do |a, b|
    if b.start_ms < a.end_ms
      raise VoiceoverError, "Пересекаются таймкоды реплик #{a.number} и #{b.number}. Для одной голосовой дорожки исправьте пересечение в SRT; файл не изменён."
    end
  end

  cues
end

def sentence_end?(text)
  text.match?(/[.!?…][»”"']?\z/)
end

def question_end?(text)
  text.match?(/[?][»”"']?\z/)
end

# A transcription ellipsis usually means that the sentence continues in the
# next cue.  It must not become a speech boundary merely because the source SRT
# was split there.
def smooth_sentence_end?(text)
  stripped = text.to_s.strip.sub(/[»”"']\z/, "")
  return false if stripped.end_with?("…") || stripped.match?(/\.{2,}\z/)
  stripped.match?(/[.!?]\z/)
end

def smooth_question_end?(text)
  text.to_s.strip.match?(/[?!][»”"']?\z/)
end

def join_speech_parts(parts)
  parts.each_with_index.map do |part, index|
    value = part.to_s.strip
    # Remove only a continuation ellipsis between cues.  A final ellipsis is
    # retained because it carries useful intonation for the voice.
    value = value.sub(/(?:\.{2,}|…)\s*\z/, "") if index < parts.length - 1
    value
  end.reject(&:empty?).join(" ").gsub(/\s+/, " ").strip
end

def split_long_speech_text(text, maximum_chars)
  words = text.to_s.strip.split(/\s+/)
  raise VoiceoverError, "Пустая длинная реплика" if words.empty?
  too_long = words.find { |word| word.length > maximum_chars }
  if too_long
    raise VoiceoverError, "Слово длиннее #{maximum_chars} знаков нельзя безопасно разделить: #{too_long[0, 40]}…"
  end

  chunks = []
  current = ""
  words.each do |word|
    candidate = current.empty? ? word : "#{current} #{word}"
    if candidate.length > maximum_chars
      chunks << current
      current = word
    else
      current = candidate
    end
  end
  chunks << current unless current.empty?
  chunks
end

# Build whole Russian sentences independently of the German cue windows.  A
# very long sentence is split only at an existing cue boundary and marked as a
# continuation, so the writer inserts a tiny pause instead of a new-sentence
# pause.
def smooth_phrases(cues, grouping: true, preferred_chars: 240, maximum_chars: 340)
  unless grouping
    return cues.flat_map do |cue|
      chunks = cue.text.length > maximum_chars ? split_long_speech_text(cue.text, maximum_chars) : [cue.text]
      duration = cue.end_ms - cue.start_ms
      chunks.each_with_index.map do |chunk, index|
        chunk_start = cue.start_ms + duration * index / chunks.length
        chunk_end = cue.start_ms + duration * (index + 1) / chunks.length
        SmoothPhrase.new(cue.number, cue.number, chunk_start, chunk_end, chunk, index < chunks.length - 1)
      end
    end
  end

  phrases = []
  collected = []
  first = nil

  flush = lambda do |continuation|
    next if collected.empty?
    phrases << SmoothPhrase.new(
      first.number, collected.last.number, first.start_ms, collected.last.end_ms,
      join_speech_parts(collected.map(&:text)), continuation
    )
    collected.clear
    first = nil
  end

  cues.each_with_index do |cue, index|
    if cue.text.length > maximum_chars
      flush.call(!smooth_sentence_end?(collected.last.text)) unless collected.empty?
      chunks = split_long_speech_text(cue.text, maximum_chars)
      chunks.each_with_index do |chunk, chunk_index|
        continues = chunk_index < chunks.length - 1 ||
                    (!smooth_sentence_end?(cue.text) && index < cues.length - 1)
        duration = cue.end_ms - cue.start_ms
        chunk_start = cue.start_ms + duration * chunk_index / chunks.length
        chunk_end = cue.start_ms + duration * (chunk_index + 1) / chunks.length
        phrases << SmoothPhrase.new(cue.number, cue.number, chunk_start, chunk_end, chunk, continues)
      end
      next
    end

    candidate = join_speech_parts(collected.map(&:text) + [cue.text])
    if !collected.empty? && candidate.length > maximum_chars
      flush.call(!smooth_sentence_end?(collected.last.text))
    end

    first ||= cue
    collected << cue
    next_cue = cues[index + 1]
    text = join_speech_parts(collected.map(&:text))
    complete = smooth_sentence_end?(cue.text)
    large_real_pause = next_cue && next_cue.start_ms - cue.end_ms >= 1_500
    useful_size = text.length >= preferred_chars
    boundary = next_cue.nil? || (complete && (useful_size || large_real_pause || smooth_question_end?(cue.text)))
    flush.call(false) if boundary
  end

  phrases
end

# Several neighbouring sentences share one timing decision.  This prevents a
# fast fragment followed by unused silence.  We still preserve genuine pauses
# of at least 1.5 seconds and add a safe planning boundary roughly every 45 s.
def smooth_islands(phrases, final_end_ms)
  islands = []
  collected = []
  island_start = nil

  phrases.each_with_index do |phrase, index|
    island_start ||= phrase.start_ms
    collected << phrase
    next_phrase = phrases[index + 1]
    real_gap = next_phrase ? next_phrase.start_ms - phrase.end_ms : nil
    elapsed = phrase.end_ms - island_start
    text_size = collected.sum { |item| item.text.length }
    completed = smooth_sentence_end?(phrase.text) && !phrase.continuation
    hard_pause = completed && real_gap && real_gap >= 1_500
    planning_limit = (completed && (elapsed >= 45_000 || text_size >= 1_600)) ||
                     elapsed >= 60_000 || text_size >= 2_200
    boundary = next_phrase.nil? || hard_pause || planning_limit
    next unless boundary

    boundary_after = next_phrase.nil? ? :end : (hard_pause ? :scene : :planning)

    finish = if next_phrase
               if hard_pause
                 # Reserve only a natural turn-taking join.  Dense Russian may
                 # borrow the rest instead of rushing and then waiting.  When
                 # speech is short, the unused room remains a real scene pause.
                 preserved = 300
                 [next_phrase.start_ms - preserved, phrase.end_ms].max
               else
                 reserved = (smooth_pause_samples(phrase) * 1000.0 / SAMPLE_RATE).round
                 [next_phrase.start_ms - reserved, phrase.end_ms].max
               end
             else
               final_end_ms
             end
    if finish <= island_start
      raise VoiceoverError, "Слишком короткий речевой фрагмент около реплики #{phrase.first_cue}. Исправьте таймкоды SRT."
    end
    islands << SpeechIsland.new(collected.dup, island_start, finish, boundary_after)
    collected.clear
    island_start = nil
  end

  islands
end

def group_cues(cues, grouping: true)
  return cues.map { |c| Phrase.new(c.number, c.number, c.start_ms, c.end_ms, c.text) } unless grouping

  groups = []
  first = nil
  collected = []

  cues.each_with_index do |cue, index|
    first ||= cue
    collected << cue
    next_cue = cues[index + 1]
    duration = cue.end_ms - first.start_ms
    gap = next_cue ? next_cue.start_ms - cue.end_ms : 10_000
    text = collected.map(&:text).join(" ")

    natural_boundary = sentence_end?(cue.text) && (duration >= 2_800 || question_end?(cue.text))
    forced_boundary = next_cue.nil? || gap > 450 || duration >= 10_000 || text.length >= 190
    next unless natural_boundary || forced_boundary

    groups << Phrase.new(first.number, cue.number, first.start_ms, cue.end_ms, text)
    first = nil
    collected = []
  end

  groups
end

# Borrow only the real pause before the next phrase; never invent extra time.
def phrase_windows(phrases)
  phrases.each_with_index.map do |phrase, index|
    next_start = phrases[index + 1]&.start_ms
    finish = next_start ? [next_start - 45, phrase.end_ms].max : phrase.end_ms
    seconds = (finish - phrase.start_ms) / 1000.0
    if seconds < 0.25
      raise VoiceoverError, "Слишком короткое окно фразы (реплики #{phrase.first_cue}–#{phrase.last_cue}): #{format('%.3f', seconds)} с. Нужно хотя бы 0,25 с; исправьте таймкоды SRT."
    end
    [finish, seconds]
  end
end

def load_replacements(program_dir, data_dir = voiceover_data_dir(program_dir))
  replacements = {
    "С 2008 года" => "С две тысячи восьмого года",
    "около 14 лет" => "около четырнадцати лет",
    "«gemma»" => "гэмма",
    "Heidak" => "Хайдак",
    "Spagyros" => "Спагирос",
    "Dr. Koll" => "доктор Колль",
    "HerbalGem" => "Хэрбалджем",
    "Instagram" => "Инстаграм",
    "Facebook" => "Фейсбук"
  }

  [File.join(program_dir, "произношение.txt"), File.join(data_dir, "произношение.txt")].uniq.each do |custom_path|
    next unless File.file?(custom_path)
    File.readlines(custom_path, encoding: "bom|utf-8").each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      source, spoken = line.split("=>", 2).map { |part| part&.strip }
      replacements[source] = spoken if source && spoken && !source.empty? && !spoken.empty?
    end
  end
  replacements
end

def prepare_for_speech(text, replacements)
  prepare_for_speech_result(text, replacements).text
end

def prepare_for_speech_result(text, replacements)
  SpeechNormalizer.normalize(text, replacements: replacements)
rescue SpeechNormalizer::Error => error
  raise VoiceoverError, "Не удалось безопасно подготовить текст для голоса: #{error.message}"
end

def validate_silero_text!(text)
  marked = text.gsub(/\+(?=[аеёиоуыэюяАЕЁИОУЫЭЮЯ])/, "")
  unsupported = marked.gsub(/[А-Яа-яЁё\s.,!?…;:—–\-()"'«»]/, "")
  return if unsupported.empty?

  preview = unsupported.each_char.uniq.first(20).map { |char| "#{char} (U+#{format('%04X', char.ord)})" }.join(", ")
  raise VoiceoverError, "после нормализации остались знаки, которые Silero может пропустить: #{preview.inspect}. Добавьте произношение или перепишите фразу."
end

def wav_pcm(path)
  bytes = File.binread(path)
  raise VoiceoverError, "say создал не WAV-файл" unless bytes.start_with?("RIFF") && bytes[8, 4] == "WAVE"

  offset = 12
  format = nil
  pcm = nil
  while offset + 8 <= bytes.bytesize
    chunk_id = bytes[offset, 4]
    chunk_size = bytes[offset + 4, 4].unpack1("V")
    chunk = bytes[offset + 8, chunk_size]
    format = chunk if chunk_id == "fmt "
    pcm = chunk if chunk_id == "data"
    offset += 8 + chunk_size + (chunk_size.odd? ? 1 : 0)
  end

  raise VoiceoverError, "В WAV отсутствуют служебные данные" unless format && pcm

  audio_format, channels, rate, _byte_rate, _align, bits = format.unpack("vvVVvv")
  unless audio_format == 1 && channels == CHANNELS && rate == SAMPLE_RATE && bits == BITS_PER_SAMPLE
    raise VoiceoverError, "Неожиданный формат WAV: format=#{audio_format}, channels=#{channels}, rate=#{rate}, bits=#{bits}"
  end

  pcm.unpack("s<*")
end

def trim_silence(samples)
  threshold = 70
  first = samples.index { |sample| sample.abs > threshold }
  last = samples.rindex { |sample| sample.abs > threshold }
  raise VoiceoverError, "Системный голос не создал слышимый звук" unless first && last

  padding = (SAMPLE_RATE * 0.045).round
  from = [first - padding, 0].max
  to = [last + padding, samples.length - 1].min
  samples[from..to]
end

def synthesize(text, path, voice, rate)
  raise VoiceoverError, "для Siri требуется контекст Shortcuts" if voice == "siri"

  args = ["/usr/bin/say"]
  args += ["-v", voice] if voice && !voice.empty? && voice != "system"
  args += ["-r", rate.to_i.to_s, "-o", path, "--file-format=WAVE", "--data-format=LEI16@#{SAMPLE_RATE}", text]
  _stdout, stderr, status = Open3.capture3(*args)
  raise VoiceoverError, "Ошибка say: #{stderr.strip}" unless status.success? && File.file?(path)

  trim_silence(wav_pcm(path))
end

def find_ffmpeg
  candidates = [
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "ffmpeg") },
    "/Applications/Subtitle Edit.app/Contents/MacOS/ffmpeg",
    "/Applications/Wondershare UniConverter 15.app/Contents/MacOS/ffmpeg",
    "/Applications/Ultimate Vocal Remover.app/Contents/Frameworks/ffmpeg"
  ].flatten
  candidates.find { |path| File.file?(path) && File.executable?(path) }
end

def build_siri_context(program_dir)
  stdout, stderr, status = Open3.capture3("/usr/bin/shortcuts", "list")
  raise VoiceoverError, "не удалось прочитать список команд: #{stderr.strip}" unless status.success?

  shortcut = stdout.lines.map(&:strip).find do |name|
    name == "Siri TTS" || name.match?(/\AСоздать голосовой аудиофайл из.*текста\z/i)
  end
  raise VoiceoverError, "не найдена команда Siri TTS" unless shortcut

  input_file = File.join(voiceover_data_dir(program_dir), "Текст для озвучки.txt")
  raise VoiceoverError, "не найден файл для Siri: #{input_file}" unless File.file?(input_file)

  ffmpeg = find_ffmpeg
  raise VoiceoverError, "не найден ffmpeg из Subtitle Edit для преобразования Siri-аудио" unless ffmpeg

  { shortcut: shortcut, input_file: input_file, ffmpeg: ffmpeg }
end

def synthesize_siri(text, wav_path, context)
  File.write(context.fetch(:input_file), text + "\n", mode: "w", encoding: "UTF-8")
  m4a_path = wav_path.sub(/\.wav\z/i, ".m4a")
  last_error = nil

  2.times do
    FileUtils.rm_f(m4a_path)
    _stdout, stderr, status = Open3.capture3(
      "/usr/bin/shortcuts", "run", context.fetch(:shortcut), "-o", m4a_path
    )
    if status.success? && File.file?(m4a_path) && File.size(m4a_path).positive?
      _convert_stdout, convert_stderr, convert_status = Open3.capture3(
        context.fetch(:ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
        "-i", m4a_path, "-ac", "1", "-ar", SAMPLE_RATE.to_s,
        "-c:a", "pcm_s16le", wav_path
      )
      if convert_status.success? && File.file?(wav_path)
        return trim_silence(wav_pcm(wav_path))
      end
      last_error = "ffmpeg: #{convert_stderr.strip}"
    else
      last_error = "Shortcuts: #{stderr.strip}"
    end
  end

  raise VoiceoverError, "Siri не создала аудио (#{last_error})"
end

# A stale Shortcut may return perfectly valid audio of the wrong file. Check
# two deliberately different inputs, not merely the existence of its output.
# This detects static/repeated input, not the exact pronunciation of every word.
def verify_siri_input(context, work_dir)
  probes = ["Да.", "Сейчас программа проверяет передачу нового текста в голосовую команду. Эта вторая проверочная фраза специально заметно длиннее первой и содержит совершенно другие слова."]
  samples = probes.each_with_index.map do |text, index|
    synthesize_siri(text, File.join(work_dir, "siri-probe-#{index}.wav"), context)
  end
  short, long = samples.map { |pcm| pcm.length.to_f / SAMPLE_RATE }
  different = Digest::SHA256.hexdigest(samples[0].pack("s<*")) != Digest::SHA256.hexdigest(samples[1].pack("s<*"))
  unless different && long >= [short * 2.5, short + 1.5].max
    raise VoiceoverError, "Siri не прошла проверку смены текста: короткая фраза #{format('%.2f', short)} с, длинная #{format('%.2f', long)} с. Возможно, «Команды» читают старый файл. Кнопкой «Файл для Siri» найдите рабочий текст ЭТОЙ версии и выберите его в верхнем блоке команды. Озвучка не сохранена."
  end
  true
end

def atempo_filter(factor)
  filters = []
  while factor > 2.0
    filters << "atempo=2.0"
    factor /= 2.0
  end
  while factor < 0.5
    filters << "atempo=0.5"
    factor /= 0.5
  end
  filters << format("atempo=%.6f", factor)
  filters.join(",")
end

def fit_tempo_without_pitch_shift(wav_path, samples, available_seconds, context)
  # Start from the same trimmed PCM whose duration we measured. Feeding the
  # untrimmed source to atempo previously required a pitch-changing fallback.
  clean_path = wav_path.sub(/\.wav\z/i, ".clean.wav")
  fitted_path = wav_path.sub(/\.wav\z/i, ".tempo.wav")
  target = (available_seconds * SAMPLE_RATE).floor
  3.times do
    return samples if samples.length <= target
    File.open(clean_path, "wb") do |file|
      file.write(wav_header(samples.length * 2))
      write_samples(file, samples)
    end
    factor = samples.length.to_f / (target * 0.98)
    _stdout, stderr, status = Open3.capture3(
      context.fetch(:ffmpeg), "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
      "-i", clean_path, "-filter:a", atempo_filter(factor),
      "-ac", "1", "-ar", SAMPLE_RATE.to_s, "-c:a", "pcm_s16le", fitted_path
    )
    raise VoiceoverError, "Не удалось подогнать темп речи: #{stderr.strip}" unless status.success? && File.file?(fitted_path)
    samples = trim_silence(wav_pcm(fitted_path))
  end
  return samples if samples.length <= target
  raise VoiceoverError, "Фраза не помещается в своё окно после подгонки темпа. Сдвигать реплики или обрезать слова программа не будет; проверьте SRT."
end

def apply_tempo_factor(wav_path, samples, factor, ffmpeg)
  return samples if (factor - 1.0).abs <= 0.001

  clean_path = wav_path.sub(/\.wav\z/i, ".smooth-source.wav")
  fitted_path = wav_path.sub(/\.wav\z/i, ".smooth-tempo.wav")
  File.open(clean_path, "wb") do |file|
    file.write(wav_header(samples.length * 2))
    write_samples(file, samples)
  end
  begin
    _stdout, stderr, status = Open3.capture3(
      ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
      "-i", clean_path, "-filter:a", atempo_filter(factor),
      "-ac", "1", "-ar", SAMPLE_RATE.to_s, "-c:a", "pcm_s16le", fitted_path
    )
    raise VoiceoverError, "Не удалось плавно подогнать темп речи: #{stderr.strip}" unless status.success? && File.file?(fitted_path)
    trim_silence(wav_pcm(fitted_path))
  ensure
    FileUtils.rm_f(clean_path)
    FileUtils.rm_f(fitted_path)
  end
end

def smooth_pause_samples(phrase)
  milliseconds = if phrase.continuation
                   80
                 elsif smooth_question_end?(phrase.text)
                   400
                 else
                   300
                 end
  (SAMPLE_RATE * milliseconds / 1000.0).round
end

# Dense Russian speech must not alternate between rushing and conspicuous
# synthetic pauses.  Keep only a tiny join while an island is accelerated;
# the TTS clip itself still retains its natural sentence cadence.
def compact_smooth_pause_samples(phrase)
  milliseconds = phrase.continuation ? 40 : 120
  (SAMPLE_RATE * milliseconds / 1000.0).round
end

# Returns [clips, pauses, common_factor, original_seconds].  The same tempo is
# used for every clip in an island; unused room is kept only after the island,
# never inserted inside a sentence.
def fit_smooth_island(raw_clips, phrases, clip_paths, available_samples, ffmpeg, previous_factor = nil)
  unless available_samples.positive?
    raise VoiceoverError, "Для речевого фрагмента нет времени: проверьте таймкоды SRT."
  end

  natural_pauses = phrases.each_with_index.map do |phrase, index|
    index == phrases.length - 1 ? 0 : smooth_pause_samples(phrase)
  end
  pauses = natural_pauses.dup
  pause_budget_limited = false
  raw_total = raw_clips.sum(&:length)
  pause_total = pauses.sum
  room_for_voice = available_samples - pause_total

  # If speech needs noticeable acceleration, remove most synthetic silence
  # before increasing tempo.  This is both clearer and more even than fast
  # speech followed by a pause.  Real scene pauses remain outside the island.
  initial_factor = room_for_voice.positive? ? raw_total.to_f / room_for_voice * 1.01 : Float::INFINITY
  compacted_pauses = initial_factor > 1.05
  if compacted_pauses
    pauses = phrases.each_with_index.map do |phrase, index|
      index == phrases.length - 1 ? 0 : compact_smooth_pause_samples(phrase)
    end
    pause_total = pauses.sum

    # Artificial joins must never cancel a lecture.  In an exceptionally
    # narrow but still positive window, spend at most 10% on joins and leave
    # the rest for complete speech.  Broken zero/negative timing still fails.
    pause_budget = [available_samples / 10, available_samples - 1].min
    pause_budget = [pause_budget, 0].max
    if pause_total > pause_budget
      pause_budget_limited = true
      if pause_total.positive?
        original_total = pause_total
        pauses = pauses.map { |pause| (pause * pause_budget.to_f / original_total).floor }
        remainder = pause_budget - pauses.sum
        pauses.each_index do |index|
          break unless remainder.positive?
          next unless natural_pauses[index].positive?
          pauses[index] += 1
          remainder -= 1
        end
      end
      pause_total = pauses.sum
    end
    room_for_voice = available_samples - pause_total
    raise VoiceoverError, "Для речевого фрагмента нет времени: проверьте таймкоды SRT." unless room_for_voice.positive?
  end

  ratio = raw_total.to_f / room_for_voice
  factor = if ratio > 1.0
             ratio * 1.01
           else
             1.0
           end
  # Keep natural speed in sparse passages and ease down after a dense island.
  # Timing still wins when acceleration is required; no speech is discarded.
  factor = [factor, [[previous_factor.to_f - 0.10, 1.0].max, 1.15].min].max if previous_factor
  fitted = raw_clips
  8.times do
    fitted = raw_clips.each_with_index.map do |samples, index|
      apply_tempo_factor(clip_paths[index], samples, factor, ffmpeg)
    end
    overflow = fitted.sum(&:length) + pause_total - available_samples
    break if overflow <= 0
    factor *= (fitted.sum(&:length).to_f / [room_for_voice, 1].max) * 1.01
    unless factor.finite? && factor.positive?
      raise VoiceoverError, "Не удалось рассчитать темп речевого фрагмента: проверьте таймкоды SRT."
    end
  end

  if fitted.sum(&:length) + pause_total > available_samples
    raise VoiceoverError, "Речевой фрагмент не поместился после подгонки темпа. Слова не обрезаны; проверьте таймкоды SRT."
  end
  # Restore only natural 300/400-ms joins between complete phrases when room
  # remains. Continuations stay tightly joined. Never recreate the old long
  # pauses after accelerated speech; larger remainder belongs at the end.
  leftover = available_samples - fitted.sum(&:length) - pauses.sum
  eligible = phrases.each_index.select { |index| index < phrases.length - 1 && !phrases[index].continuation }
  restore_natural_pauses = !pause_budget_limited || factor <= 1.05
  unless !restore_natural_pauses || eligible.empty? || leftover <= 0
    remaining = leftover
    eligible.each_with_index do |index, position|
      share = remaining / (eligible.length - position)
      addition = [share, natural_pauses[index] - pauses[index]].min
      addition = [addition, 0].max
      pauses[index] += addition
      remaining -= addition
    end
  end
  [fitted, pauses, factor, raw_total.to_f / SAMPLE_RATE]
end

def fit_phrase(text, work_dir, number, voice, base_rate, max_rate, available_seconds, siri_context = nil)
  if voice == "siri"
    clip_path = File.join(work_dir, format("clip-%04d.wav", number))
    samples = synthesize_siri(text, clip_path, siri_context)
    duration = samples.length.to_f / SAMPLE_RATE
    return [samples, "Siri", false, duration] if duration <= available_seconds

    fitted = fit_tempo_without_pitch_shift(clip_path, samples, available_seconds, siri_context)
    return [fitted, "Siri", true, duration]
  end

  if voice == "silero"
    clip_path = File.join(work_dir, format("clip-%04d.wav", number))
    siri_context.fetch(:worker).synthesize(text, clip_path)
    samples = trim_silence(wav_pcm(clip_path))
    duration = samples.length.to_f / SAMPLE_RATE
    label = "Silero/#{siri_context.fetch(:speaker)}"
    return [samples, label, false, duration] if duration <= available_seconds

    fitted = fit_tempo_without_pitch_shift(clip_path, samples, available_seconds, siri_context)
    return [fitted, label, true, duration]
  end

  rate = base_rate
  attempts = 0
  samples = nil
  clip_path = File.join(work_dir, format("clip-%04d.wav", number))

  loop do
    attempts += 1
    samples = synthesize(text, clip_path, voice, rate)
    duration = samples.length.to_f / SAMPLE_RATE
    return [samples, rate, false, duration] if duration <= available_seconds

    required = (rate * duration / available_seconds * 1.025).ceil
    new_rate = [[required, rate + 8].max, max_rate].min
    break if new_rate == rate || attempts >= 5
    rate = new_rate
  end

  duration = samples.length.to_f / SAMPLE_RATE
  ffmpeg = siri_context && siri_context[:ffmpeg] || find_ffmpeg
  raise VoiceoverError, "Для подгонки Milena без изменения высоты нужен FFmpeg. Установите его или увеличьте окно реплики в SRT." unless ffmpeg
  fitted = fit_tempo_without_pitch_shift(clip_path, samples, available_seconds, { ffmpeg: ffmpeg })
  [fitted, rate, true, duration]
end

def synthesize_natural_phrase(text, clip_path, voice, base_rate, context)
  case voice
  when "siri"
    synthesize_siri(text, clip_path, context)
  when "silero"
    trim_silence(wav_pcm(clip_path))
  else
    synthesize(text, clip_path, voice, base_rate)
  end
end

def write_silence(file, samples)
  zero_chunk = "\0" * (SAMPLE_RATE * 2)
  bytes = samples * 2
  while bytes.positive?
    amount = [bytes, zero_chunk.bytesize].min
    file.write(zero_chunk.byteslice(0, amount))
    bytes -= amount
  end
end

def write_samples(file, samples)
  samples.each_slice(SAMPLE_RATE * 10) { |slice| file.write(slice.pack("s<*")) }
end

def wav_header(data_bytes)
  [
    "RIFF", 36 + data_bytes, "WAVE",
    "fmt ", 16, 1, CHANNELS, SAMPLE_RATE, SAMPLE_RATE * CHANNELS * 2, CHANNELS * 2, BITS_PER_SAMPLE,
    "data", data_bytes
  ].pack("A4VA4A4VvvVVvvA4V")
end

def choose_srt
  script = 'POSIX path of (choose file with prompt "Выберите русский файл субтитров SRT")'
  stdout, _stderr, status = Open3.capture3("/usr/bin/osascript", "-e", script)
  raise VoiceoverError, "Файл не выбран" unless status.success?
  stdout.strip
end

def run_voiceover(argv = ARGV)
  $stdout.sync = true
  options = {
    voice: "silero",
    base_rate: 180,
    max_rate: 270,
    grouping: true,
    rhythm: "smooth",
    max_segments: nil,
    output: nil,
    silero_speaker: "kseniya"
  }

  output_created_by_run = false
  report_created_by_run = false
  run_completed = false
  output_path = nil
  report_path = nil

  begin
  OptionParser.new do |parser|
    parser.banner = "Использование: srt_voiceover.rb [параметры] файл.srt"
    parser.on("--voice NAME", "siri, silero, system, Milena или другой голос из say -v '?'") { |value| options[:voice] = value }
    parser.on("--silero-speaker NAME", "kseniya") { |value| options[:silero_speaker] = value }
    parser.on("--rate N", Integer, "базовая скорость, слов в минуту (по умолчанию 180)") { |value| options[:base_rate] = value }
    parser.on("--max-rate N", Integer, "максимальная скорость (по умолчанию 270)") { |value| options[:max_rate] = value }
    parser.on("--rhythm NAME", "smooth (по умолчанию) или strict") { |value| options[:rhythm] = value }
    parser.on("--no-group", "не объединять соседние блоки") { options[:grouping] = false }
    parser.on("--max-segments N", Integer, "создать только первые N фраз — для проверки") { |value| options[:max_segments] = value }
    parser.on("--output PATH", "путь к выходному WAV") { |value| options[:output] = value }
  end.parse!(argv)

  input_path = argv.shift || choose_srt
  input_path = File.expand_path(input_path)
  raise VoiceoverError, "Файл не найден: #{input_path}" unless File.file?(input_path)
  raise VoiceoverError, "Нужен файл с расширением .srt" unless File.extname(input_path).downcase == ".srt"
  raise VoiceoverError, "Режим ритма должен быть smooth или strict" unless %w[smooth strict].include?(options[:rhythm])

  # All entry points share this lock: Siri's Shortcut reads one shared text file.
  # Keep it held until the engine has finished, including child processes.
  engine_lock = File.open(File.join(Dir.tmpdir, "srt-voiceover-#{Process.uid}.lock"), File::RDWR | File::CREAT, 0o600)
  unless engine_lock.flock(File::LOCK_EX | File::LOCK_NB)
    raise VoiceoverError, "Уже идёт другая озвучка. Дождитесь её завершения и повторите запуск."
  end
  cues = parse_srt(input_path)
  all_phrases = if options[:rhythm] == "smooth"
                  smooth_phrases(cues, grouping: options[:grouping])
                else
                  group_cues(cues, grouping: options[:grouping])
                end
  all_windows = options[:rhythm] == "strict" ? phrase_windows(all_phrases) : nil
  phrases = all_phrases
  if options[:max_segments]
    raise VoiceoverError, "Число тестовых фраз должно быть положительным" unless options[:max_segments].positive?
    phrases = all_phrases.first(options[:max_segments])
  end
  if options[:max_segments] && phrases.length < all_phrases.length
    next_start = all_phrases.fetch(phrases.length).start_ms
    borrowed_end = [next_start - 45, phrases.last.end_ms + 15_000].min
    final_end_ms = [borrowed_end, phrases.last.end_ms].max
  else
    final_end_ms = cues.last.end_ms
  end
  windows = options[:rhythm] == "strict" ? all_windows.first(phrases.length) : nil
  islands = options[:rhythm] == "smooth" ? smooth_islands(phrases, final_end_ms) : nil

  output_path = options[:output] || input_path.sub(/\.srt\z/i, ".wav")
  raise VoiceoverError, "Выходной файл движка должен иметь расширение .wav" unless File.extname(output_path).downcase == ".wav"
  report_path = output_path.sub(/\.wav\z/i, ".report.txt")
  [output_path, report_path].each do |path|
    raise VoiceoverError, "Файл уже существует: #{path}. Используйте GUI для выбора копии или замены." if File.exist?(path) || File.symlink?(path)
  end
  program_dir = File.expand_path(__dir__)
  replacements = load_replacements(program_dir)
  normalization_results = phrases.each_with_index.map do |phrase, index|
    prepare_for_speech_result(phrase.text, replacements)
  rescue VoiceoverError => error
    raise VoiceoverError, "Фраза #{index + 1}, реплики #{phrase.first_cue}–#{phrase.last_cue}: #{error.message}"
  end
  if options[:voice] == "silero"
    normalization_results.each_with_index do |result, index|
      validate_silero_text!(result.text)
    rescue VoiceoverError => error
      phrase = phrases[index]
      raise VoiceoverError, "Фраза #{index + 1}, реплики #{phrase.first_cue}–#{phrase.last_cue}: #{error.message}"
    end
  end
  siri_context = options[:voice] == "siri" ? build_siri_context(program_dir) : nil
  if options[:voice] == "silero"
    allowed_silero_speakers = %w[kseniya]
    unless allowed_silero_speakers.include?(options[:silero_speaker])
      raise VoiceoverError, "Неизвестный голос Silero: #{options[:silero_speaker]}"
    end
    ffmpeg = find_ffmpeg
    raise VoiceoverError, "не найден ffmpeg для подгонки темпа Silero" unless ffmpeg
    puts "Загружаю Silero v5.5 (при первом запуске потребуется немного времени)…"
    pool_size = options[:rhythm] == "smooth" ? [SileroWorkerPool::DEFAULT_SIZE, phrases.length].min : 1
    worker_pool = SileroWorkerPool.new(program_dir, options[:silero_speaker], size: pool_size)
    siri_context = { worker: worker_pool, speaker: options[:silero_speaker], ffmpeg: ffmpeg }
  end
  puts "SRT: #{input_path}"
  puts "Реплик: #{cues.length}; фраз для озвучки: #{phrases.length}"
  voice_label = case options[:voice]
                when "siri" then "Siri: голос и скорость из приложения «Команды»"
                when "silero" then "Silero v5.5 Russian / #{options[:silero_speaker]}"
                when "system" then "системный через say"
                else options[:voice]
                end
  puts "Голос: #{voice_label}"
  puts "Ритм: #{options[:rhythm] == 'smooth' ? 'плавный, по целым предложениям' : 'точно по исходным меткам'}"
  if options[:voice] == "siri"
    puts "Скорость: задана внутри команды Siri"
  elsif options[:voice] == "silero"
    puts "Скорость: естественная; длинные фразы подгоняются без изменения высоты голоса"
  else
    puts "Скорость: #{options[:base_rate]}–#{options[:max_rate]} слов/мин"
  end
  puts

  report = []
  report << "Исходный SRT: #{input_path}"
  report << "Запрошенный голос: #{options[:voice]}"
  report << "Базовая скорость: #{options[:base_rate]}"
  report << "Максимальная скорость: #{options[:max_rate]}"
  report << "Ритм: #{options[:rhythm]}"
  report << "Фраз: #{phrases.length}"
  normalized_replacements = normalization_results.sum { |result| result.audit[:replacements].length }
  foreign_tokens = normalization_results.sum { |result| result.audit[:foreign_tokens].length }
  report << "Локальных преобразований для речи: #{normalized_replacements}"
  report << "Латинских/иностранных токенов подготовлено: #{foreign_tokens}"
  report << ""

  FileUtils.mkdir_p(File.dirname(output_path))
  current_voice = options[:voice]
  current_sample = 0
  fallback_announced = false

  Dir.mktmpdir(".srt-voiceover-engine-", File.dirname(output_path)) do |work_dir|
    if current_voice == "siri"
      puts "Проверяю, что Siri читает новый текст…"
      verify_siri_input(siri_context, work_dir)
      puts "Проверка смены текста Siri пройдена."
    end
    spoken_texts = normalization_results.map(&:text)
    normalization_results.each_with_index do |result, index|
      result.audit[:replacements].each do |entry|
        report << "NORMALIZE #{index + 1} | #{entry[:kind]} | #{entry[:source]} => #{entry[:replacement]}"
      end
      result.audit[:foreign_tokens].each do |entry|
        report << "NORMALIZE #{index + 1} | #{entry[:strategy]} | #{entry[:source]} => #{entry[:replacement]}"
      end
    end
    smooth_clip_paths = phrases.each_index.map { |index| File.join(work_dir, format("clip-%04d.wav", index + 1)) }
    if current_voice == "silero" && options[:rhythm] == "smooth"
      jobs = phrases.each_index.map { |index| [index, spoken_texts[index], smooth_clip_paths[index]] }
      worker_pool.synthesize_all(jobs) do |done, total|
        puts "Silero: подготовлено #{done}/#{total} фраз"
      end
    end

    File.open(output_path, File::RDWR | File::CREAT | File::EXCL, 0o600) do |output|
      output_created_by_run = true
      output.binmode
      output.write("\0" * 44)

      if options[:rhythm] == "smooth"
        ffmpeg = siri_context && siri_context[:ffmpeg] || find_ffmpeg
        raise VoiceoverError, "Для плавной подгонки речи нужен FFmpeg" unless ffmpeg
        phrase_cursor = 0

        previous_island = nil
        previous_factor = nil
        islands.each_with_index do |island, island_index|
          nominal_target = (island.start_ms * SAMPLE_RATE / 1000.0).round
          target_sample = if previous_island&.boundary_after == :planning
                            boundary_pause = if previous_factor && previous_factor > 1.05
                                               compact_smooth_pause_samples(previous_island.phrases.last)
                                             else
                                               smooth_pause_samples(previous_island.phrases.last)
                                             end
                            [current_sample + boundary_pause, nominal_target].min
                          else
                            nominal_target
                          end
          if target_sample > current_sample
            write_silence(output, target_sample - current_sample)
            current_sample = target_sample
          elsif target_sample < current_sample
            raise VoiceoverError, "Речевой фрагмент #{island_index + 1} пересекается с предыдущим. Результат не сохранён."
          end

          island_indices = (phrase_cursor...(phrase_cursor + island.phrases.length)).to_a
          raw_clips = island_indices.map do |index|
            begin
              synthesize_natural_phrase(
                spoken_texts[index], smooth_clip_paths[index], current_voice,
                options[:base_rate], siri_context
              )
            rescue VoiceoverError => error
              if current_voice == "system"
                current_voice = "Milena"
                unless fallback_announced
                  warn "\nСистемный голос недоступен для экспорта (#{error.message})."
                  warn "Автоматически использую голос Milena.\n\n"
                  fallback_announced = true
                end
                retry
              end
              raise
            end
          end
          island_end_sample = (island.end_ms * SAMPLE_RATE / 1000.0).floor
          available_samples = island_end_sample - current_sample
          clips, pauses, factor, original_seconds = fit_smooth_island(
            raw_clips, island.phrases, island_indices.map { |index| smooth_clip_paths[index] },
            available_samples, ffmpeg, previous_factor
          )
          if factor > 1.10
            severity = factor > 1.15 ? "вынужденно ускорен" : "ускорен"
            explanation = factor > 1.15 ? " Все слова сохранены; лишние паузы сокращены." : ""
            message = "Речевой фрагмент #{island_index + 1} (реплики #{island.phrases.first.first_cue}–#{island.phrases.last.last_cue}) #{severity} ×#{format('%.2f', factor)}.#{explanation}"
            puts "\nПРЕДУПРЕЖДЕНИЕ: #{message}"
            report << "ПРЕДУПРЕЖДЕНИЕ: #{message}"
          end

          island.phrases.each_with_index do |phrase, local_index|
            index = island_indices[local_index]
            write_samples(output, clips[local_index])
            current_sample += clips[local_index].length
            if pauses[local_index].positive?
              write_silence(output, pauses[local_index])
              current_sample += pauses[local_index]
            end
            percent = ((index + 1) * 100.0 / phrases.length).round
            warning = (factor - 1.0).abs > 0.001 ? " [общий темп ×#{format('%.2f', factor)}]" : ""
            print "\r#{percent.to_s.rjust(3)}%  Фраза #{index + 1}/#{phrases.length}, плавно#{warning}      "
            $stdout.flush
            report << format(
              "%04d | cues %d-%d | island %d | tempo ×%.3f | voice %.3f s%s | %s",
              index + 1, phrase.first_cue, phrase.last_cue, island_index + 1, factor,
              raw_clips[local_index].length.to_f / SAMPLE_RATE,
              phrase.continuation ? " | CONTINUATION" : "", spoken_texts[index]
            )
          end
          report << format("ISLAND %d | %.3f–%.3f | natural %.3f s | tempo ×%.3f",
                           island_index + 1, island.start_ms / 1000.0, island.end_ms / 1000.0,
                           original_seconds, factor)
          phrase_cursor += island.phrases.length
          island_indices.each { |index| FileUtils.rm_f(smooth_clip_paths[index]) }
          previous_island = island
          previous_factor = factor
        end
      else
        phrases.each_with_index do |phrase, index|
          window_end_ms, available = windows.fetch(index)
          spoken = spoken_texts[index]

          begin
            samples, rate, squeezed, original_duration = fit_phrase(
              spoken, work_dir, index + 1, current_voice,
              options[:base_rate], options[:max_rate], available, siri_context
            )
          rescue VoiceoverError => error
            if current_voice == "system"
              current_voice = "Milena"
              unless fallback_announced
                warn "\nСистемный голос недоступен для экспорта (#{error.message})."
                warn "Автоматически использую голос Milena.\n\n"
                fallback_announced = true
              end
              retry
            end
            raise
          end

          target_sample = (phrase.start_ms * SAMPLE_RATE / 1000.0).round
          if target_sample > current_sample
            write_silence(output, target_sample - current_sample)
            current_sample = target_sample
          elsif target_sample < current_sample
            raise VoiceoverError, "Фраза #{index + 1} вышла за предыдущий таймкод. Дорожка не будет сохранена со сдвигом."
          end
          raise VoiceoverError, "Фраза #{index + 1} длиннее отведённого окна." if samples.length > (available * SAMPLE_RATE).floor
          if squeezed && original_duration / available > 1.5
            message = "Фраза #{index + 1} (реплики #{phrase.first_cue}–#{phrase.last_cue}): сильное ускорение ×#{format('%.2f', original_duration / available)}."
            puts "\nПРЕДУПРЕЖДЕНИЕ: #{message}"
            report << "ПРЕДУПРЕЖДЕНИЕ: #{message}"
          end
          write_samples(output, samples)
          current_sample += samples.length
          percent = ((index + 1) * 100.0 / phrases.length).round
          warning = squeezed ? " [подгонка темпа без изменения высоты]" : ""
          print "\r#{percent.to_s.rjust(3)}%  Фраза #{index + 1}/#{phrases.length}, скорость #{rate}#{warning}      "
          $stdout.flush
          report << format(
            "%04d | cues %d-%d | %8.3f–%8.3f | rate %4s | voice %.3f s / window %.3f s%s | %s",
            index + 1, phrase.first_cue, phrase.last_cue,
            phrase.start_ms / 1000.0, window_end_ms / 1000.0,
            rate, original_duration, available, squeezed ? " | TEMPO_FIT" : "", spoken
          )
        end
      end

      final_sample = (final_end_ms * SAMPLE_RATE / 1000.0).round
      raise VoiceoverError, "Аудио длиннее временной шкалы SRT. Результат со сдвигом не сохранён." if current_sample > final_sample
      if current_sample < final_sample
        write_silence(output, final_sample - current_sample)
        current_sample = final_sample
      end

      data_bytes = current_sample * CHANNELS * (BITS_PER_SAMPLE / 8)
      output.seek(0)
      output.write(wav_header(data_bytes))
    end
  end

  actual_voice = case current_voice
                 when "siri" then "Siri: голос из Apple «Команды» (номер программно не проверяется)"
                 when "silero" then "Silero v5.5 / #{options[:silero_speaker]}"
                 when "system" then "системный"
                 else current_voice
                 end
  report.insert(2, "Фактический голос: #{actual_voice}")
  File.open(report_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    report_created_by_run = true
    file.write(report.join("\n") + "\n")
  end
  run_completed = true
  puts "\n\nГотово: #{output_path}"
  puts "Отчёт: #{report_path}"
  puts "Фактический голос: #{actual_voice}"
  puts "Длительность: #{format('%.3f', final_end_ms / 1000.0)} с"
  0
  rescue StandardError => error
    unless run_completed
      FileUtils.rm_f(output_path) if output_created_by_run && output_path
      FileUtils.rm_f(report_path) if report_created_by_run && report_path
    end
    warn "\nОшибка: #{error.message}"
    1
  ensure
    worker_pool&.close
    engine_lock&.close
  end
end

exit(run_voiceover) if $PROGRAM_NAME == __FILE__

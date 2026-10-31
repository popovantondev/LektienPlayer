require 'minitest/autorun'
require_relative '../../Sources/PlayerSpeech/Resources/Engine/srt_voiceover'

# Isolate timing decisions from FFmpeg. Integration checks cover real PCM.
def apply_tempo_factor(_path, samples, factor, _ffmpeg)
  samples.first((samples.length / factor).floor)
end

class SmoothTempoTest < Minitest::Test
  def test_sparse_phrase_keeps_natural_speed
    phrase = SmoothPhrase.new(1, 1, 0, 2000, 'Проверка темпа.', false)
    result = fit_smooth_island([[1] * 1000], [phrase], ['test.wav'], 2000, nil)
    assert_equal 1.0, result[2]
  end

  def test_transition_after_dense_island_eases_down
    phrase = SmoothPhrase.new(1, 1, 0, 2000, 'Проверка темпа.', false)
    result = fit_smooth_island([[1] * 1000], [phrase], ['test.wav'], 2000, nil, 1.5)
    assert_in_delta 1.15, result[2], 0.0001
  end
end

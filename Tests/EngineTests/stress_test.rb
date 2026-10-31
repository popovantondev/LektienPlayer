# frozen_string_literal: true
require "minitest/autorun"
require_relative "../../Sources/PlayerSpeech/Resources/Engine/srt_voiceover"

class StressTest < Minitest::Test
  def test_accents_reach_silero_without_becoming_arithmetic
    source = "Дверной замо́к и стари́нный за́мок; H+ и Cl⁻.".freeze
    spoken = prepare_for_speech(source, {})
    assert_equal "Дверной зам+ок и стар+инный з+амок; эйч плюс и Кл минус.", spoken
    validate_silero_text!(spoken)
    assert_equal "Дверной замо́к и стари́нный за́мок; H+ и Cl⁻.", source
  end

  def test_invalid_stress_is_not_silently_dropped
    assert_raises(VoiceoverError) { prepare_for_speech("зам́ок", {}) }
    assert_raises(VoiceoverError) { prepare_for_speech("за́мо́к", {}) }
    assert_raises(VoiceoverError) { validate_silero_text!("зам+к") }
    assert_raises(VoiceoverError) { validate_silero_text!("з++амок") }
    validate_silero_text!("з+амок, зам+ок, ёлка")
  end

  def test_russian_k_is_allowed_and_lookalikes_are_identifiable
    validate_silero_text!("к К к врачу")
    assert_equal "кей", prepare_for_speech("k", {})
    error = assert_raises(VoiceoverError) { validate_silero_text!("κ") }
    assert_includes error.message, "U+03BA"
  end
end

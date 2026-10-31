# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../Sources/PlayerSpeech/Resources/Engine/srt_voiceover"

class FormulaNormalizationTest < Minitest::Test
  def test_kappa_identifier_reaches_voice_without_changing_subtitles
    source = "Подавление NF-κB.".freeze
    assert_equal "Подавление эн эф каппа бэ.", prepare_for_speech(source, {})
    assert_equal "Подавление NF-κB.", source
    %w[NFκB NF-ΚB NF-ϰB].each do |variant|
      assert_equal "эн эф каппа бэ", prepare_for_speech(variant, {})
    end
    assert_equal "каппа", prepare_for_speech("κ", {})
    refute_equal "эн эф каппа бэ", prepare_for_speech("XNF-κB", {})
    assert_raises(VoiceoverError) { prepare_for_speech("κλ", {}) }
  end

  def test_greek_symbols_work_without_model_hints_and_preserve_quantities
    source = "TNF-α, β-клетки и IFN-γ; 5 μg, H⁺.".freeze
    spoken = prepare_for_speech(source, {})
    assert_includes spoken, "альфа"
    assert_includes spoken, "бета"
    assert_includes spoken, "гамма"
    assert_includes spoken, "пять микрограммов"
    assert_includes spoken, "плюс"
    validate_silero_text!(spoken)
    assert_equal "TNF-α, β-клетки и IFN-γ; 5 μg, H⁺.", source
  end

  def test_subscript_formulae_preserve_indices_without_changing_subtitles
    source = "H₂S, H₂O₂, CO₂ и NaHCO₃.".freeze
    result = SpeechNormalizer.normalize(source)
    assert_equal SpeechNormalizer.normalize("H2S, H2O2, CO2 и NaHCO3.").text, result.text
    refute_match(/\p{N}|\p{Latin}/, result.text)
    assert_equal "H₂S, H₂O₂, CO₂ и NaHCO₃.", source
    assert_equal %w[₂ ₂ ₂ ₂ ₃], result.audit[:replacements].select { |row| row[:kind] == "unicode_digit" }.map { |row| row[:source] }
  end

  def test_lower_indices_are_not_confused_with_powers
    assert_equal SpeechNormalizer.normalize("C12H22O11").text, SpeechNormalizer.normalize("C₁₂H₂₂O₁₁").text
    assert_raises(SpeechNormalizer::UnresolvedNumberError) { SpeechNormalizer.normalize("x²") }
  end

  def test_uncertainty_marker_and_compound_abbreviation_reach_voice_without_losing_text
    source = "ME/CFS и [неразборчиво].".freeze
    spoken = SpeechNormalizer.normalize(source).text
    assert_equal "эм и си эф эс и (неразборчиво).", spoken
    validate_silero_text!(spoken)
    assert_equal "ME/CFS и [неразборчиво].", source
  end

  def test_ionic_charge_and_standalone_plus_are_spoken
    source = "H+, Na+ и A + B".freeze
    spoken = SpeechNormalizer.normalize(source).text
    assert_equal SpeechNormalizer.normalize("H плюс, Na плюс и A плюс B").text, spoken
    validate_silero_text!(spoken)
    assert_equal "H+, Na+ и A + B", source
    assert_equal "плюс пять", SpeechNormalizer.normalize("+5").text
    charged = SpeechNormalizer.normalize("H⁺, Na⁺, Cl⁻ и HCO₃⁻.").text
    assert_equal SpeechNormalizer.normalize("H плюс, Na плюс, Cl минус и HCO3 минус.").text, charged
    validate_silero_text!(charged)
  end
end

# frozen_string_literal: true

# Deterministic, offline preparation of Russian text for a speech engine.
# The source SRT text is never changed: normalize works on a copy and returns
# both the spoken text and a machine-readable audit trail.
require "date"

module SpeechNormalizer
  class Error < StandardError; end
  class UnsupportedScriptError < Error; end
  class UnresolvedNumberError < Error; end

  Result = Struct.new(:text, :audit, keyword_init: true)

  ONES = {
    masculine: %w[ноль один два три четыре пять шесть семь восемь девять],
    feminine: %w[ноль одна две три четыре пять шесть семь восемь девять],
    neuter: %w[ноль одно два три четыре пять шесть семь восемь девять]
  }.freeze
  TEENS = %w[десять одиннадцать двенадцать тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать].freeze
  TENS = [nil, nil, "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"].freeze
  HUNDREDS = [nil, "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"].freeze

  GENITIVE_ONES = {
    masculine: %w[нуля одного двух трёх четырёх пяти шести семи восьми девяти],
    feminine: %w[нуля одной двух трёх четырёх пяти шести семи восьми девяти]
  }.freeze
  GENITIVE_TEENS = %w[десяти одиннадцати двенадцати тринадцати четырнадцати пятнадцати шестнадцати семнадцати восемнадцати девятнадцати].freeze
  GENITIVE_TENS = [nil, nil, "двадцати", "тридцати", "сорока", "пятидесяти", "шестидесяти", "семидесяти", "восьмидесяти", "девяноста"].freeze
  GENITIVE_HUNDREDS = [nil, "ста", "двухсот", "трёхсот", "четырёхсот", "пятисот", "шестисот", "семисот", "восьмисот", "девятисот"].freeze

  SCALES = [
    [1_000_000_000_000_000_000, %w[квинтиллион квинтиллиона квинтиллионов], :masculine],
    [1_000_000_000_000_000, %w[квадриллион квадриллиона квадриллионов], :masculine],
    [1_000_000_000_000, %w[триллион триллиона триллионов], :masculine],
    [1_000_000_000, %w[миллиард миллиарда миллиардов], :masculine],
    [1_000_000, %w[миллион миллиона миллионов], :masculine],
    [1_000, %w[тысяча тысячи тысяч], :feminine]
  ].freeze

  GENITIVE_SCALES = [
    [1_000_000_000_000_000_000, ["квинтиллиона", "квинтиллионов"], :masculine],
    [1_000_000_000_000_000, ["квадриллиона", "квадриллионов"], :masculine],
    [1_000_000_000_000, ["триллиона", "триллионов"], :masculine],
    [1_000_000_000, ["миллиарда", "миллиардов"], :masculine],
    [1_000_000, ["миллиона", "миллионов"], :masculine],
    [1_000, ["тысячи", "тысяч"], :feminine]
  ].freeze

  ORDINALS = {
    1 => "первый", 2 => "второй", 3 => "третий", 4 => "четвёртый", 5 => "пятый",
    6 => "шестой", 7 => "седьмой", 8 => "восьмой", 9 => "девятый", 10 => "десятый",
    11 => "одиннадцатый", 12 => "двенадцатый", 13 => "тринадцатый", 14 => "четырнадцатый",
    15 => "пятнадцатый", 16 => "шестнадцатый", 17 => "семнадцатый", 18 => "восемнадцатый",
    19 => "девятнадцатый", 20 => "двадцатый", 30 => "тридцатый", 40 => "сороковой",
    50 => "пятидесятый", 60 => "шестидесятый", 70 => "семидесятый", 80 => "восьмидесятый",
    90 => "девяностый", 100 => "сотый", 200 => "двухсотый", 300 => "трёхсотый",
    400 => "четырёхсотый", 500 => "пятисотый", 600 => "шестисотый", 700 => "семисотый",
    800 => "восьмисотый", 900 => "девятисотый", 1_000 => "тысячный", 2_000 => "двухтысячный"
  }.freeze

  FRACTION_DENOMINATORS = {
    2 => ["вторая", "вторых"], 3 => ["третья", "третьих"], 4 => ["четвёртая", "четвёртых"],
    5 => ["пятая", "пятых"], 6 => ["шестая", "шестых"], 7 => ["седьмая", "седьмых"],
    8 => ["восьмая", "восьмых"], 9 => ["девятая", "девятых"], 10 => ["десятая", "десятых"],
    11 => ["одиннадцатая", "одиннадцатых"], 12 => ["двенадцатая", "двенадцатых"],
    16 => ["шестнадцатая", "шестнадцатых"], 20 => ["двадцатая", "двадцатых"],
    100 => ["сотая", "сотых"], 1_000 => ["тысячная", "тысячных"]
  }.freeze

  MONTHS = %w[января февраля марта апреля мая июня июля августа сентября октября ноября декабря].freeze

  # The spelling variants intentionally include both Russian and common Latin
  # abbreviations. A quantity is replaced as one unit, so Silero never receives
  # a bare digit followed by an abbreviation it may silently skip.
  UNIT_RULES = [
    { pattern: "(?:мкг|mcg|[µμ]g|микрограмм(?:а|ов|ы)?)", forms: %w[микрограмм микрограмма микрограммов], gender: :masculine },
    { pattern: "(?:мг|mg|миллиграмм(?:а|ов|ы)?)", forms: %w[миллиграмм миллиграмма миллиграммов], gender: :masculine },
    { pattern: "(?:мл|ml|миллилитр(?:а|ов|ы)?)", forms: %w[миллилитр миллилитра миллилитров], gender: :masculine },
    { pattern: "(?:кг|kg|килограмм(?:а|ов|ы)?)", forms: %w[килограмм килограмма килограммов], gender: :masculine },
    { pattern: "(?:г|g|грамм(?:а|ов|ы)?)", forms: %w[грамм грамма граммов], gender: :masculine },
    { pattern: "(?:л|l|литр(?:а|ов|ы)?)", forms: %w[литр литра литров], gender: :masculine },
    { pattern: "(?:капля|капли|капель|drops?)", forms: %w[капля капли капель], gender: :feminine },
    { pattern: "(?:таб[.]?|таблетка|таблетки|таблеток|tablets?)", forms: %w[таблетка таблетки таблеток], gender: :feminine },
    { pattern: "(?:раз|раза|разов|times?)", forms: %w[раз раза раз], gender: :masculine },
    { pattern: "(?:мин[.]?|минута|минуты|минут|minutes?)", forms: %w[минута минуты минут], gender: :feminine },
    { pattern: "(?:ч[.]?|час|часа|часов|hours?)", forms: %w[час часа часов], gender: :masculine },
    { pattern: "(?:день|дня|дней|days?)", forms: %w[день дня дней], gender: :masculine },
    { pattern: "(?:неделя|недели|недель|weeks?)", forms: %w[неделя недели недель], gender: :feminine },
    { pattern: "(?:месяц|месяца|месяцев|months?)", forms: %w[месяц месяца месяцев], gender: :masculine }
  ].freeze

  KNOWN_FOREIGN = {
    "standardized extract" => "стандартизированный экстракт",
    "food supplement" => "пищевая добавка",
    "daily dose" => "суточная доза",
    "Hypericum perforatum" => "гиперикум перфоратум",
    "Echinacea purpurea" => "эхинацея пурпуреа",
    "Withania somnifera" => "витания сомнифера",
    "Ginkgo biloba" => "гинкго билоба",
    "Crataegus monogyna" => "кратэгус моногина",
    "Ribes nigrum" => "рибес нигрум",
    "Ficus carica" => "фикус карика",
    "Rubus idaeus" => "рубус идеус",
    "Vaccinium vitis-idaea" => "вакциниум витис-идеа",
    "Tilia tomentosa" => "тилиа томентоза",
    "Betula pubescens" => "бетула пубесценс",
    "Rosmarinus officinalis" => "розмаринус оффициналис",
    "Crataegus" => "кратэгус",
    "Hypericum" => "гиперикум",
    "perforatum" => "перфоратум",
    "Echinacea" => "эхинацея",
    "purpurea" => "пурпуреа",
    "Withania" => "витания",
    "somnifera" => "сомнифера",
    "Ginkgo" => "гинкго",
    "biloba" => "билоба",
    "sleep" => "слип",
    "stress" => "стресс",
    "extract" => "экстракт",
    "tincture" => "тинктура",
    "dosage" => "дозировка",
    "HerbalGem" => "хэрбалджем",
    "Spagyros" => "спагирос",
    "Instagram" => "инстаграм",
    "Facebook" => "фейсбук"
  }.freeze

  ABBREVIATIONS = {
    "ME/CFS" => "эм и си эф эс",
    "GABA" => "гамма-аминомасляная кислота",
    "DNA" => "дэ эн ка",
    "RNA" => "эр эн ка",
    "PH" => "пэ аш"
  }.freeze

  ENGLISH_LETTER_NAMES = {
    "a" => "эй", "b" => "би", "c" => "си", "d" => "ди", "e" => "и", "f" => "эф",
    "g" => "джи", "h" => "эйч", "i" => "ай", "j" => "джей", "k" => "кей", "l" => "эл",
    "m" => "эм", "n" => "эн", "o" => "оу", "p" => "пи", "q" => "кью", "r" => "ар",
    "s" => "эс", "t" => "ти", "u" => "ю", "v" => "ви", "w" => "дабл-ю", "x" => "икс",
    "y" => "уай", "z" => "зед"
  }.freeze

  GREEK_LETTER_NAMES = {
    "α" => "альфа", "β" => "бета", "γ" => "гамма", "δ" => "дельта",
    "ε" => "эпсилон", "ζ" => "дзета", "η" => "эта", "θ" => "тета",
    "ι" => "йота", "κ" => "каппа", "λ" => "лямбда", "μ" => "мю",
    "ν" => "ню", "ξ" => "кси", "ο" => "омикрон", "π" => "пи",
    "ρ" => "ро", "σ" => "сигма", "τ" => "тау", "υ" => "ипсилон",
    "φ" => "фи", "χ" => "хи", "ψ" => "пси", "ω" => "омега",
    "ϰ" => "каппа", "ϑ" => "тета", "ϕ" => "фи", "ς" => "сигма"
  }.freeze

  LATIN_LETTERS = {
    "a" => "а", "b" => "б", "d" => "д", "e" => "е", "f" => "ф", "g" => "г",
    "h" => "х", "i" => "и", "j" => "й", "k" => "к", "l" => "л", "m" => "м",
    "n" => "н", "o" => "о", "p" => "п", "q" => "к", "r" => "р", "s" => "с",
    "t" => "т", "u" => "у", "v" => "в", "w" => "в", "x" => "кс", "y" => "и", "z" => "ц"
  }.freeze

  # Zero code points of Unicode decimal digit blocks. Mathematical styled
  # digits form five consecutive ten-character blocks and are handled below.
  DECIMAL_ZEROES = [
    0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66,
    0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0, 0x0F20, 0x1040,
    0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90, 0x1B50, 0x1BB0,
    0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0,
    0xFF10, 0x104A0, 0x10D30, 0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0,
    0x11450, 0x114D0, 0x11650, 0x116C0, 0x11730, 0x118E0, 0x11950, 0x11C50,
    0x11D50, 0x11DA0, 0x16A60, 0x16AC0, 0x16B50, 0x1E950
  ].freeze

  class << self
    def normalize(text, replacements: {})
      Normalizer.new(replacements).normalize(text)
    end

    def integer_words(value, gender: :masculine)
      string = value.to_s
      sign = string.start_with?("-") ? "минус " : (string.start_with?("+") ? "плюс " : "")
      digits = string.sub(/\A[+-]/, "")
      raise Error, "Ожидалось целое число: #{value.inspect}" unless digits.match?(/\A\d+\z/)
      return sign + digit_sequence_words(digits) if digits.length > 18 || (digits.length > 1 && digits.start_with?("0"))

      number = digits.to_i
      return sign + "ноль" if number.zero?

      parts = []
      remainder = number
      SCALES.each do |scale, forms, scale_gender|
        group = remainder / scale
        next if group.zero?

        parts << triplet_words(group, scale_gender)
        parts << plural_form(group, forms)
        remainder %= scale
      end
      parts << triplet_words(remainder, gender) unless remainder.zero?
      sign + parts.reject(&:empty?).join(" ")
    end

    def genitive_integer_words(value, gender: :masculine)
      string = value.to_s
      sign = string.start_with?("-") ? "минус " : (string.start_with?("+") ? "плюс " : "")
      digits = string.sub(/\A[+-]/, "")
      raise Error, "Ожидалось целое число: #{value.inspect}" unless digits.match?(/\A\d+\z/)
      return sign + digit_sequence_words(digits) if digits.length > 18 || (digits.length > 1 && digits.start_with?("0"))

      number = digits.to_i
      return sign + "нуля" if number.zero?

      parts = []
      remainder = number
      GENITIVE_SCALES.each do |scale, forms, scale_gender|
        group = remainder / scale
        next if group.zero?

        parts << genitive_triplet_words(group, scale_gender)
        parts << (group % 10 == 1 && group % 100 != 11 ? forms[0] : forms[1])
        remainder %= scale
      end
      parts << genitive_triplet_words(remainder, gender) unless remainder.zero?
      sign + parts.reject(&:empty?).join(" ")
    end

    def decimal_words(raw)
      whole, fraction = raw.to_s.sub(/\A\+/, "").split(/[,.]/, 2)
      raise Error, "Ожидалась десятичная дробь: #{raw.inspect}" unless whole && fraction && !fraction.empty?

      negative = whole.start_with?("-")
      whole = whole.delete_prefix("-")
      denominator = { 1 => ["десятая", "десятых"], 2 => ["сотая", "сотых"], 3 => ["тысячная", "тысячных"],
                      4 => ["десятитысячная", "десятитысячных"], 5 => ["стотысячная", "стотысячных"],
                      6 => ["миллионная", "миллионных"] }[fraction.length]
      raise Error, "Поддерживаются десятичные дроби не более чем с шестью знаками: #{raw}" unless denominator

      whole_number = whole.to_i
      fraction_number = fraction.to_i
      whole_form = whole_number % 10 == 1 && whole_number % 100 != 11 ? "целая" : "целых"
      fraction_form = fraction_number == 1 ? denominator[0] : denominator[1]
      prefix = negative ? "минус " : ""
      "#{prefix}#{integer_words(whole, gender: :feminine)} #{whole_form} #{integer_words(fraction_number, gender: :feminine)} #{fraction_form}"
    end

    def digit_sequence_words(digits)
      digits.each_char.map { |digit| ONES[:masculine][digit.to_i] }.join(" ")
    end

    private

    def triplet_words(number, gender)
      number %= 1_000
      words = []
      words << HUNDREDS[number / 100] if number >= 100
      tail = number % 100
      if tail.between?(10, 19)
        words << TEENS[tail - 10]
      else
        words << TENS[tail / 10] if tail >= 20
        words << ONES.fetch(gender)[tail % 10] if (tail % 10).positive?
      end
      words.compact.join(" ")
    end

    def genitive_triplet_words(number, gender)
      number %= 1_000
      words = []
      words << GENITIVE_HUNDREDS[number / 100] if number >= 100
      tail = number % 100
      if tail.between?(10, 19)
        words << GENITIVE_TEENS[tail - 10]
      else
        words << GENITIVE_TENS[tail / 10] if tail >= 20
        words << GENITIVE_ONES.fetch(gender)[tail % 10] if (tail % 10).positive?
      end
      words.compact.join(" ")
    end

    def plural_form(number, forms)
      value = number.abs
      return forms[2] if (value % 100).between?(11, 14)
      return forms[0] if value % 10 == 1
      return forms[1] if (value % 10).between?(2, 4)

      forms[2]
    end
  end

  class Normalizer
    def initialize(replacements)
      unless replacements.respond_to?(:each)
        raise ArgumentError, "replacements должен быть Hash или списком пар"
      end

      @user_replacements = []
      replacements.each do |source, replacement|
        next if source.nil? || replacement.nil?

        source = source.to_s.unicode_normalize(:nfc)
        replacement = replacement.to_s.unicode_normalize(:nfc)
        next if source.empty?

        @user_replacements << [source, replacement]
      end
    end

    def normalize(text)
      raise ArgumentError, "text должен быть строкой" unless text.is_a?(String)

      @audit = { replacements: [], foreign_tokens: [] }
      spoken = text.dup.unicode_normalize(:nfc)
      spoken = apply_user_replacements(spoken)
      spoken = normalize_punctuation(spoken)
      spoken = translate_unicode_digits(spoken)
      spoken = normalize_inverse_unit_exponents(spoken)
      reject_non_decimal_numbers!(spoken)
      reject_scientific_notation!(spoken)
      reject_ambiguous_separators!(spoken)
      spoken = replace_known_identifiers(spoken)
      spoken = replace_known_foreign(spoken)
      spoken = replace_dates(spoken)
      spoken = replace_times(spoken)
      spoken = replace_years(spoken)
      spoken = replace_phone_numbers(spoken)
      spoken = collapse_grouped_numbers(spoken)
      spoken = replace_temperatures(spoken)
      spoken = replace_percentages(spoken)
      spoken = replace_number_signs(spoken)
      spoken = replace_unit_ranges(spoken)
      spoken = replace_ratio_quantities(spoken)
      spoken = replace_fractions(spoken)
      spoken = replace_quantities(spoken)
      spoken = replace_generic_ranges(spoken)
      spoken = replace_decimals(spoken)
      spoken = replace_mixed_tokens(spoken)
      spoken = replace_integers(spoken)
      spoken = replace_standalone_units(spoken)
      # Numeric signs have already been spoken; retain remaining plus signs
      # (for example the ionic charge in H+) rather than letting Silero skip them.
      spoken = audited_gsub(spoken, /[+⁺₊⁻₋]/, "charge_sign") do |match|
        word = %w[⁻ ₋].include?(match[0]) ? "минус" : "плюс"
        " #{word}" + (match.post_match.match?(/\A[\p{L}\p{N}]/) ? " " : "")
      end
      # Units (including μg) and numeric indices are already resolved. Read
      # isolated Greek symbols by name; do not spell whole Greek words.
      spoken = audited_gsub(spoken, /(?<!\p{Greek})[#{GREEK_LETTER_NAMES.keys.join}](?!\p{Greek})/i, "greek_letter") do |match|
        " #{GREEK_LETTER_NAMES.fetch(match[0].downcase)} "
      end
      spoken = transliterate_latin(spoken)
      # Acute accents are unambiguous source notation. Convert only after mathematical
      # plus signs have been spoken, so H+ can never become a stress marker.
      if spoken.match?(/\u0301[\p{L}\p{M}]*\u0301/)
        raise Error, "В одном слове указано несколько ударений"
      end
      spoken = audited_gsub(spoken, /([аеёиоуыэюяАЕЁИОУЫЭЮЯ])\u0301/, "stress") { |match| "+#{match[1]}" }
      raise Error, "Знак ударения должен стоять после русской гласной" if spoken.include?("\u0301")
      spoken = spoken.gsub(/[\t\r\f\v ]+/, " ").gsub(/ *\n */, "\n").strip
      verify_output!(spoken)

      Result.new(text: spoken, audit: @audit)
    end

    private

    def apply_user_replacements(text)
      entries = @user_replacements.each_with_index.sort_by { |(source, _replacement), index| [-source.length, index] }.map(&:first)
      return text if entries.empty?

      alternatives = entries.map { |source, _replacement| Regexp.escape(source) }.join("|")
      pattern = Regexp.new(alternatives, Regexp::IGNORECASE)
      text.gsub(pattern) do |actual|
        source, replacement = entries.find { |candidate, _| candidate.casecmp?(actual) }
        replacement ||= actual
        record_replacement("user", actual, replacement)
        replacement
      end
    end

    def normalize_punctuation(text)
      replacements = {
        "“" => '"', "”" => '"', "„" => '"', "‟" => '"',
        "’" => "'", "‘" => "'", "‚" => "'", "‛" => "'",
        "‑" => "-", "−" => "-", "[" => "(", "]" => ")"
      }
      text.gsub(/[“”„‟’‘‚‛‑−\[\]]/) do |actual|
        replacement = replacements.fetch(actual)
        record_replacement("punctuation", actual, replacement)
        replacement
      end
    end

    def translate_unicode_digits(text)
      text.each_char.map do |character|
        # Subscripts in formulae are numeric indices, unlike superscript powers.
        subscript = character.ord.between?(0x2080, 0x2089)
        next character unless subscript || character.match?(/\p{Nd}/)
        next character if character.match?(/[0-9]/)

        codepoint = character.ord
        value = nil
        if subscript
          value = codepoint - 0x2080
        elsif codepoint.between?(0x1D7CE, 0x1D7FF)
          value = (codepoint - 0x1D7CE) % 10
        else
          zero = DECIMAL_ZEROES.find { |candidate| codepoint.between?(candidate, candidate + 9) }
          value = codepoint - zero if zero
        end
        raise UnresolvedNumberError, "Неизвестная цифра: #{character.inspect}" unless value

        replacement = value.to_s
        record_replacement("unicode_digit", character, replacement)
        replacement
      end.join
    end

    def reject_non_decimal_numbers!(text)
      unresolved = text.scan(/\p{N}/).reject { |character| character.match?(/[0-9]/) }
      return if unresolved.empty?

      raise UnresolvedNumberError, "После нормализации остались цифровые знаки: #{unresolved.uniq.join(', ')}"
    end

    def reject_scientific_notation!(text)
      token = text[/((?<![\p{L}\p{N}])[+-]?\d+(?:\s*[,.]\s*\d+)?\s*[eE]\s*[+-]?\s*\d+(?![\p{L}\p{N}]))/, 1]
      return unless token

      raise Error, "Научная запись #{token.inspect} неоднозначна для озвучки. Перепишите значение словами."
    end

    def reject_ambiguous_separators!(text)
      token = text[/((?<!\d)[1-9]\d*[,.]\d{3}(?!\d))/, 1]
      return unless token

      raise Error, "Число #{token.inspect} неоднозначно: разделитель может означать тысячи или дробь. Перепишите значение словами."
    end

    def replace_known_identifiers(text)
      # Kappa belongs to this scientific identifier; do not replace lookalikes
      # globally or change the text retained for subtitle display.
      text = audited_gsub(text, /(?<![\p{L}\p{M}\p{N}])NF\s*[-–—]?\s*[κϰ]\s*B(?![\p{L}\p{M}\p{N}])/i, "identifier") do |_match|
        "эн эф каппа бэ"
      end
      text = audited_gsub(text, /(?<![\p{L}\p{N}])(?:омега|Omega|[ωΩ])\s*[-–—]\s*(\d+(?:\s*[-–—]\s*\d+)*)(?!\d)/i, "omega") do |match|
        values = match[1].scan(/\d+/).map { |value| SpeechNormalizer.integer_words(value) }
        spoken_values = if values.length == 1
                          values.first
                        else
                          "#{values[0...-1].join(', ')} и #{values.last}"
                        end
        prefix = initial_uppercase?(match[0]) ? "Омега" : "омега"
        "#{prefix} #{spoken_values}"
      end
      text = audited_gsub(text, /(?<![\p{L}\p{N}])((?:коэнзим\s+)?)CoQ\s*[-–—]?\s*(\d+)(?![\p{Latin}\p{N}])/i, "identifier") do |match|
        prefix = match[1].empty? ? "коэнзим" : match[1].strip
        "#{prefix} ку #{SpeechNormalizer.integer_words(match[2])}"
      end
      text = audited_gsub(text, /(?<![\p{Latin}\p{N}])Q\s*(\d+)(?![\p{Latin}\p{N}])/i, "identifier") do |match|
        "ку #{SpeechNormalizer.integer_words(match[1])}"
      end
      text = audited_gsub(text, /(?<![\p{L}\p{N}])([+-]?\d+(?:[,.]\d+)?)\s*(?:I\s*\.?\s*[UE](?:\s*\.(?=\s+\p{L}))?|М\s*\.?\s*Е(?:\s*\.(?=\s+\p{L}))?)(?![\p{L}\p{N}])/i, "international_unit") do |match|
        raw = match[1]
        quantity = raw.match?(/[,.]/) ? SpeechNormalizer.decimal_words(raw) : SpeechNormalizer.integer_words(raw)
        "#{quantity} международных единиц"
      end
      text = audited_gsub(text, /(?<![\p{Latin}\p{N}])((?:витамин\s+)?)B[\s-]*(\d{1,3})(?![\p{Latin}\p{N}])/i, "identifier") do |match|
        prefix = match[1].empty? ? "витамин" : match[1].strip
        "#{prefix} бэ #{SpeechNormalizer.integer_words(match[2])}"
      end
      text = audited_gsub(text, /(?<![\p{Latin}\p{N}])CYP\s*(\d+)\s*([A-Z])\s*(\d+)(?![\p{Latin}\p{N}])/i, "identifier") do |match|
        letter = ENGLISH_LETTER_NAMES.fetch(match[2].downcase)
        "цитохром пи #{SpeechNormalizer.integer_words(match[1])} #{letter} #{SpeechNormalizer.integer_words(match[3])}"
      end
      text = audited_gsub(text, /(?<![\p{Latin}\p{N}])COVID[\s-]*(\d+)(?![\p{Latin}\p{N}])/i, "identifier") do |match|
        "ковид #{SpeechNormalizer.integer_words(match[1])}"
      end

      abbreviation_pattern = /(?<![\p{Latin}\p{N}])(?:#{ABBREVIATIONS.keys.sort_by { |key| -key.length }.map { |key| Regexp.escape(key) }.join("|")})(?![\p{Latin}\p{N}])/i
      text.gsub(abbreviation_pattern) do |actual|
        replacement = ABBREVIATIONS.fetch(actual.upcase)
        record_foreign(actual, replacement, "known_abbreviation")
        replacement
      end
    end

    def replace_known_foreign(text)
      alternatives = KNOWN_FOREIGN.keys.sort_by { |key| -key.length }.map { |key| Regexp.escape(key) }.join("|")
      pattern = Regexp.new("(?<![\\p{Latin}\\p{N}])(?:#{alternatives})(?![\\p{Latin}\\p{N}])", Regexp::IGNORECASE)
      text.gsub(pattern) do |actual|
        key = KNOWN_FOREIGN.keys.find { |candidate| candidate.casecmp?(actual) }
        replacement = preserve_initial_capital(actual, KNOWN_FOREIGN.fetch(key))
        record_foreign(actual, replacement, "known")
        replacement
      end
    end

    def replace_dates(text)
      text = audited_gsub(text, /(?<!\d)(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})(?!\d)/, "date") do |match|
        year = match[1].to_i
        month = match[2].to_i
        day = match[3].to_i
        validate_date!(year, month, day, match[0])
        "#{ordinal_words(day, gender: :neuter)} #{MONTHS[month - 1]} #{year_words(year, :genitive)} года"
      end
      text = audited_gsub(text, /(?<!\d)(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})(?!\d)/, "date") do |match|
        day = match[1].to_i
        month = match[2].to_i
        year = match[3].to_i
        validate_date!(year, month, day, match[0])
        "#{ordinal_words(day, gender: :neuter)} #{MONTHS[month - 1]} #{year_words(year, :genitive)} года"
      end
      months = MONTHS.join("|")
      audited_gsub(text, /(?<!\d)(\d{1,2})\s+(#{months})(?!\p{Cyrillic})/i, "date") do |match|
        day = match[1].to_i
        raise Error, "Некорректный день месяца: #{match[0]}" unless day.between?(1, 31)

        "#{ordinal_words(day, grammatical_case: :genitive)} #{match[2].downcase}"
      end
    end

    def replace_times(text)
      audited_gsub(text, /(?<!\d)(\d{1,2}):(\d{2})(?::(\d{2}))?(?!\d)/, "time") do |match|
        hour = match[1].to_i
        minute = match[2].to_i
        second = match[3]&.to_i
        unless hour.between?(0, 23) && minute.between?(0, 59) && (second.nil? || second.between?(0, 59))
          raise Error, "Некорректное время: #{match[0]}"
        end

        words = "#{SpeechNormalizer.integer_words(hour)} #{plural_form(hour, %w[час часа часов])}"
        if minute.positive?
          words += " #{SpeechNormalizer.integer_words(minute, gender: :feminine)} #{plural_form(minute, %w[минута минуты минут])}"
        end
        if second && second.positive?
          words += " #{SpeechNormalizer.integer_words(second, gender: :feminine)} #{plural_form(second, %w[секунда секунды секунд])}"
        end
        words
      end
    end

    def replace_years(text)
      text = audited_gsub(text, /\b(с|до|после|от)\s+(\d{4})(?:\s*(?:года|г\.))?/i, "year") do |match|
        "#{match[1]} #{year_words(match[2].to_i, :genitive)} года"
      end
      text = audited_gsub(text, /\bв\s+(\d{4})(?:\s*(?:году|г\.))?/i, "year") do |match|
        "в #{year_words(match[1].to_i, :prepositional)} году"
      end
      audited_gsub(text, /(?<!\d)(\d{4})\s*(год|года|году|г\.)(?!\p{Cyrillic})/i, "year") do |match|
        grammatical_case = match[2].downcase.start_with?("году") ? :prepositional : (match[2].downcase == "год" ? :nominative : :genitive)
        noun = { nominative: "год", genitive: "года", prepositional: "году" }.fetch(grammatical_case)
        "#{year_words(match[1].to_i, grammatical_case)} #{noun}"
      end
    end

    def replace_phone_numbers(text)
      audited_gsub(text, /(?<![\d+])\+\s*\d(?:[\d\s()\-]{5,}\d)/, "phone") do |match|
        groups = match[0].sub(/\A\+\s*/, "").scan(/\d+/)
        "плюс #{groups.map { |group| SpeechNormalizer.digit_sequence_words(group) }.join(", ")}"
      end
    end

    def collapse_grouped_numbers(text)
      audited_gsub(text, /(?<!\d)\d{1,3}(?:[ \u00A0\u202F'’]\d{3})+(?!\d)/, "grouped_integer") do |match|
        match[0].gsub(/[ \u00A0\u202F'’]/, "")
      end
    end

    def replace_temperatures(text)
      pattern = /(?<![\p{N}])([+-]?\d+(?:[,.]\d+)?)\s*(?:°\s*[CcСс]|градус(?:а|ов)?\s+Цельсия)(?![\p{L}\p{N}])/i
      audited_gsub(text, pattern, "temperature") do |match|
        raw = match[1]
        if raw.match?(/[,.]/)
          "#{SpeechNormalizer.decimal_words(raw)} градуса Цельсия"
        else
          value = raw.to_i
          "#{SpeechNormalizer.integer_words(raw)} #{plural_form(value, %w[градус градуса градусов])} Цельсия"
        end
      end
    end

    def replace_percentages(text)
      audited_gsub(text, /(?<![\p{N}])([+-]?\d+(?:[,.]\d+)?)\s*(?:%|percent(?:s)?)(?![\p{L}\p{N}])/i, "percent") do |match|
        raw = match[1]
        if raw.match?(/[,.]/)
          "#{SpeechNormalizer.decimal_words(raw)} процента"
        else
          value = raw.to_i
          "#{SpeechNormalizer.integer_words(raw)} #{plural_form(value, %w[процент процента процентов])}"
        end
      end
    end

    def replace_number_signs(text)
      audited_gsub(text, /№\s*([+-]?\d+)/, "number_sign") do |match|
        "номер #{SpeechNormalizer.integer_words(match[1])}"
      end
    end

    def replace_unit_ranges(text)
      UNIT_RULES.each do |rule|
        pattern = Regexp.new("(?<![\\p{L}\\p{N}])([+-]?\\d+(?:[,.]\\d+)?)\\s*[-–—]\\s*([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{rule[:pattern]})(?![\\p{L}\\p{N}])", Regexp::IGNORECASE)
        text = audited_gsub(text, pattern, "unit_range") do |match|
          first = range_endpoint_words(match[1], rule[:gender])
          last = range_endpoint_words(match[2], rule[:gender])
          "от #{first} до #{last} #{rule[:forms][2]}"
        end
      end
      text
    end

    def replace_ratio_quantities(text)
      units = UNIT_RULES.map { |rule| "(?:#{rule[:pattern]})" }.join("|")
      inverse_unit = Regexp.new(
        "(?<![\\p{L}\\p{N}])([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{units})" \
        "\\s+(#{units})\\s*(?:\\^\\s*)?-\\s*1(?![\\p{L}\\p{N}])",
        Regexp::IGNORECASE
      )
      text = audited_gsub(text, inverse_unit, "unit_inverse_ratio") do |match|
        numerator_rule = unit_rule_for(match[2])
        denominator_rule = unit_rule_for(match[3])
        "#{quantity_words(match[1], numerator_rule)} на #{denominator_rule[:forms][0]}"
      end

      with_number = Regexp.new(
        "(?<![\\p{L}\\p{N}])([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{units})" \
        "\\s*/\\s*([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{units})(?![\\p{L}\\p{N}])",
        Regexp::IGNORECASE
      )
      text = audited_gsub(text, with_number, "unit_ratio") do |match|
        numerator_rule = unit_rule_for(match[2])
        denominator_rule = unit_rule_for(match[4])
        "#{quantity_words(match[1], numerator_rule)} на #{quantity_words(match[3], denominator_rule)}"
      end

      without_number = Regexp.new(
        "(?<![\\p{L}\\p{N}])([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{units})" \
        "\\s*/\\s*(#{units})(?![\\p{L}\\p{N}])",
        Regexp::IGNORECASE
      )
      text = audited_gsub(text, without_number, "unit_ratio") do |match|
        numerator_rule = unit_rule_for(match[2])
        denominator_rule = unit_rule_for(match[3])
        "#{quantity_words(match[1], numerator_rule)} на #{denominator_rule[:forms][0]}"
      end

      standalone = Regexp.new("(?<![\\p{L}])(#{units})\\s*/\\s*(#{units})(?![\\p{L}])", Regexp::IGNORECASE)
      audited_gsub(text, standalone, "unit_ratio") do |match|
        numerator_rule = unit_rule_for(match[1])
        denominator_rule = unit_rule_for(match[2])
        "#{numerator_rule[:forms][0]} на #{denominator_rule[:forms][0]}"
      end
    end

    def normalize_inverse_unit_exponents(text)
      units = UNIT_RULES.map { |rule| "(?:#{rule[:pattern]})" }.join("|")
      pattern = Regexp.new("(#{units})\\s*⁻¹", Regexp::IGNORECASE)
      audited_gsub(text, pattern, "inverse_unit_exponent") { |match| "#{match[1]}-1" }
    end

    def replace_fractions(text)
      text = audited_gsub(text, /(?<!\d)(\d+)\s*\/\s*(\d+)(?!\d)/, "fraction") do |match|
        fraction_words(match[1], match[2])
      end
      text
    end

    def replace_quantities(text)
      UNIT_RULES.each do |rule|
        pattern = Regexp.new("(?<![\\p{L}\\p{N}])([+-]?\\d+(?:[,.]\\d+)?)\\s*(#{rule[:pattern]})(?![\\p{L}\\p{N}])", Regexp::IGNORECASE)
        text = audited_gsub(text, pattern, "unit") do |match|
          quantity_words(match[1], rule)
        end
      end
      text
    end

    def replace_generic_ranges(text)
      audited_gsub(text, /(?<![\p{L}\p{N}-])([+-]?\d+(?:[,.]\d+)?)\s*[-–—]\s*([+-]?\d+(?:[,.]\d+)?)(?![\p{N}-])/, "range") do |match|
        "от #{range_endpoint_words(match[1], :masculine)} до #{range_endpoint_words(match[2], :masculine)}"
      end
    end

    def replace_decimals(text)
      audited_gsub(text, /(?<![\p{L}\p{N}])([+-]?\d+[,.]\d+)(?![\p{N}])/, "decimal") do |match|
        SpeechNormalizer.decimal_words(match[1])
      end
    end

    def replace_mixed_tokens(text)
      pattern = /(?<![\p{Latin}\p{N}])(?=[\p{Latin}\p{N}-]*\p{Latin})(?=[\p{Latin}\p{N}-]*\p{N})[\p{Latin}\p{N}]+(?:-[\p{Latin}\p{N}]+)*(?![\p{Latin}\p{N}])/
      text.gsub(pattern) do |actual|
        replacement = mixed_token_words(actual)
        record_foreign(actual, replacement, "mixed_identifier")
        replacement
      end
    end

    def replace_integers(text)
      audited_gsub(text, /(?<![\p{L}\p{N}])([+-]?\d+)(?![\p{N}])/, "integer") do |match|
        SpeechNormalizer.integer_words(match[1])
      end
    end

    def replace_standalone_units(text)
      replacements = {
        "мкг" => "микрограмм", "мг" => "миллиграмм", "мл" => "миллилитр", "кг" => "килограмм"
      }
      alternatives = replacements.keys.map { |key| Regexp.escape(key) }.join("|")
      pattern = Regexp.new("(?<!\\p{Cyrillic})(?:#{alternatives})(?!\\p{Cyrillic})", Regexp::IGNORECASE)
      audited_gsub(text, pattern, "standalone_unit") { |match| replacements.fetch(match[0].downcase) }
    end

    def transliterate_latin(text)
      pattern = /\p{Latin}[\p{Latin}\p{M}]*(?:[-'’][\p{Latin}\p{M}]+)*/
      text.gsub(pattern) do |actual|
        replacement = transliterate_token(actual)
        record_foreign(actual, replacement, "transliteration")
        replacement
      end
    end

    def mixed_token_words(token)
      token.scan(/\p{Latin}+|\d+|-/).reject { |part| part == "-" }.map do |part|
        if part.match?(/\A\d+\z/)
          SpeechNormalizer.integer_words(part)
        elsif part.length == 1 || (part.length <= 4 && part == part.upcase)
          spell_latin_letters(part)
        else
          transliterate_token(part)
        end
      end.join(" ")
    end

    def transliterate_token(token)
      return spell_latin_letters(token) if token.length == 1 || (token.length <= 4 && token == token.upcase)

      token.split(/([-’'])/).map do |part|
        next part if part.match?(/\A[-’']\z/)

        transliterate_word(part)
      end.join
    end

    def transliterate_word(word)
      capitalized = initial_uppercase?(word)
      value = word.downcase
      value = value.gsub("ä", "э").gsub("ö", "ё").gsub("ü", "ю").gsub("ß", "сс")
      value = value.gsub("æ", "э").gsub("œ", "ё").gsub("ø", "ё").gsub("ł", "л")
      value = value.gsub("ð", "д").gsub("þ", "т")
      value = value.each_char.map do |character|
        character.match?(/\p{Cyrillic}/) ? character : character.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
      end.join
      value = value.sub(/\Asp/, "шп").sub(/\Ast/, "шт")
      {
        "tsch" => "ч", "sch" => "ш", "sh" => "ш", "zh" => "ж", "kh" => "х",
        "ph" => "ф", "th" => "т", "ch" => "х", "qu" => "кв", "ck" => "к",
        "ei" => "ай", "ie" => "и", "eu" => "ой", "ae" => "э", "oe" => "ё",
        "ue" => "ю", "ng" => "нг"
      }.each { |source, replacement| value = value.gsub(source, replacement) }

      characters = value.each_char.to_a
      transliterated = characters.each_with_index.map do |character, index|
        next character if character.match?(/\p{Cyrillic}/)
        if character == "c"
          characters[index + 1]&.match?(/[eiy]/) ? "ц" : "к"
        else
          mapped = LATIN_LETTERS[character]
          raise Error, "Нет правила транслитерации для #{character.inspect} в #{word.inspect}" unless mapped

          mapped
        end
      end.join
      capitalized ? transliterated.sub(/\A\p{Cyrillic}/) { |letter| letter.upcase } : transliterated
    end

    def spell_latin_letters(token)
      token.downcase.each_char.map do |letter|
        ENGLISH_LETTER_NAMES.fetch(letter) do
          raise Error, "Нет названия латинской буквы #{letter.inspect}"
        end
      end.join(" ")
    end

    def fraction_words(numerator_raw, denominator_raw)
      numerator = numerator_raw.to_i
      denominator = denominator_raw.to_i
      forms = FRACTION_DENOMINATORS[denominator]
      raise Error, "Неизвестное произношение дроби #{numerator_raw}/#{denominator_raw}" unless forms

      numerator_words = SpeechNormalizer.integer_words(numerator_raw, gender: :feminine)
      "#{numerator_words} #{numerator == 1 ? forms[0] : forms[1]}"
    end

    def ordinal_words(number, gender: :masculine, grammatical_case: :nominative)
      component = ordinal_component(number)
      base = ORDINALS.fetch(component) { raise Error, "Неизвестное порядковое числительное: #{number}" }
      prefix_number = number - component
      word = decline_ordinal(base, gender, grammatical_case)
      prefix_number.positive? ? "#{SpeechNormalizer.integer_words(prefix_number)} #{word}" : word
    end

    def ordinal_component(number)
      return number if ORDINALS.key?(number)
      tail = number % 100
      return tail if tail.between?(10, 19)
      return number % 10 if (number % 10).positive?
      return tail if tail.positive? && ORDINALS.key?(tail)

      hundreds = number % 1_000
      return hundreds if hundreds.positive? && ORDINALS.key?(hundreds)

      raise Error, "Неизвестное порядковое числительное: #{number}"
    end

    def decline_ordinal(word, gender, grammatical_case)
      if word == "третий"
        return "третьего" if grammatical_case == :genitive
        return "третьем" if grammatical_case == :prepositional
        return "третье" if gender == :neuter
        return word
      end

      case grammatical_case
      when :genitive
        word.sub(/(?:ый|ой)\z/, "ого").sub(/ий\z/, "его")
      when :prepositional
        word.sub(/(?:ый|ой)\z/, "ом").sub(/ий\z/, "ем")
      when :nominative
        gender == :neuter ? word.sub(/(?:ый|ой)\z/, "ое").sub(/ий\z/, "ее") : word
      else
        raise Error, "Неизвестный падеж: #{grammatical_case}"
      end
    end

    def year_words(year, grammatical_case)
      raise Error, "Год вне поддерживаемого диапазона: #{year}" unless year.between?(1_000, 2_999)

      ordinal_words(year, grammatical_case: grammatical_case)
    end

    def range_endpoint_words(raw, gender)
      raw.match?(/[,.]/) ? SpeechNormalizer.decimal_words(raw) : SpeechNormalizer.genitive_integer_words(raw, gender: gender)
    end

    def quantity_words(raw, rule)
      if raw.match?(/[,.]/)
        "#{SpeechNormalizer.decimal_words(raw)} #{rule[:forms][1]}"
      else
        value = raw.to_i
        "#{SpeechNormalizer.integer_words(raw, gender: rule[:gender])} #{plural_form(value, rule[:forms])}"
      end
    end

    def unit_rule_for(value)
      @unit_rule_cache ||= {}
      @unit_rule_cache[value.downcase] ||= UNIT_RULES.find do |rule|
        Regexp.new("\\A(?:#{rule[:pattern]})\\z", Regexp::IGNORECASE).match?(value)
      end || raise(Error, "Неизвестная единица измерения: #{value}")
    end

    def validate_date!(year, month, day, original)
      raise Error, "Некорректная дата: #{original}" unless Date.valid_date?(year, month, day)
    end

    def plural_form(number, forms)
      value = number.abs
      return forms[2] if (value % 100).between?(11, 14)
      return forms[0] if value % 10 == 1
      return forms[1] if (value % 10).between?(2, 4)

      forms[2]
    end

    def audited_gsub(text, pattern, kind)
      text.gsub(pattern) do |actual|
        match = Regexp.last_match
        replacement = yield(match)
        record_replacement(kind, actual, replacement)
        replacement
      end
    end

    def record_replacement(kind, source, replacement)
      @audit[:replacements] << { kind: kind, source: source, replacement: replacement }
    end

    def record_foreign(source, replacement, strategy)
      @audit[:foreign_tokens] << { source: source, replacement: replacement, strategy: strategy }
    end

    def preserve_initial_capital(source, replacement)
      initial_uppercase?(source) ? replacement.sub(/\A\p{Cyrillic}/) { |letter| letter.upcase } : replacement
    end

    def initial_uppercase?(text)
      letter = text[/\p{L}/]
      letter && letter == letter.upcase && letter != letter.downcase
    end

    def verify_output!(text)
      if text.match?(/\p{Latin}/)
        raise Error, "После нормализации осталась латиница: #{text.scan(/\p{Latin}+/).uniq.join(', ')}"
      end

      if text.match?(/\p{N}/)
        numbers = text.scan(/\p{N}+/).uniq.join(", ")
        raise UnresolvedNumberError, "После нормализации остались цифровые знаки: #{numbers}"
      end

      unsupported = []
      current = +""
      text.each_char do |character|
        if character.match?(/\p{L}/) && !character.match?(/\p{Cyrillic}/)
          current << character
        elsif !current.empty?
          unsupported << current
          current = +""
        end
      end
      unsupported << current unless current.empty?
      unless unsupported.empty?
        details = unsupported.uniq.map { |token| "#{token} (#{token.codepoints.map { |value| format('U+%04X', value) }.join(' ')})" }
        raise UnsupportedScriptError, "Неподдерживаемая письменность: #{details.join(', ')}"
      end
    end
  end
end

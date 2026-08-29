// SPDX-License-Identifier: AGPL-3.0-or-later

class TranslationLanguage {
  final String code;
  final String name;

  const TranslationLanguage(this.code, this.name);
}

/// Special target-language value that follows the app's resolved system
/// locale. It is valid for message translation targets, but not source or
/// input-translation languages.
const systemTranslationLanguageCode = 'system';

const translationLanguages = <TranslationLanguage>[
  TranslationLanguage('ar', 'العربية'),
  TranslationLanguage('az', 'Azərbaycanca'),
  TranslationLanguage('be', 'Беларуская'),
  TranslationLanguage('bn', 'বাংলা'),
  TranslationLanguage('bo', 'བོད་སྐད་'),
  TranslationLanguage('ca', 'Català'),
  TranslationLanguage('cs', 'Čeština'),
  TranslationLanguage('da', 'Dansk'),
  TranslationLanguage('de', 'Deutsch'),
  TranslationLanguage('el', 'Ελληνικά'),
  TranslationLanguage('en', 'English'),
  TranslationLanguage('eo', 'Esperanto'),
  TranslationLanguage('es', 'Español'),
  TranslationLanguage('et', 'Eesti'),
  TranslationLanguage('eu', 'Euskara'),
  TranslationLanguage('fa', 'فارسی'),
  TranslationLanguage('fi', 'Suomi'),
  TranslationLanguage('fil', 'Filipino'),
  TranslationLanguage('fr', 'Français'),
  TranslationLanguage('ga', 'Gaeilge'),
  TranslationLanguage('gl', 'Galego'),
  TranslationLanguage('he', 'עברית'),
  TranslationLanguage('hi', 'हिन्दी'),
  TranslationLanguage('hr', 'Hrvatski'),
  TranslationLanguage('hu', 'Magyar'),
  TranslationLanguage('ia', 'Interlingua'),
  TranslationLanguage('id', 'Bahasa Indonesia'),
  TranslationLanguage('ie', 'Interlingue'),
  TranslationLanguage('it', 'Italiano'),
  TranslationLanguage('ja', '日本語'),
  TranslationLanguage('ka', 'ქართული'),
  TranslationLanguage('kab', 'Taqbaylit'),
  TranslationLanguage('ko', '한국어'),
  TranslationLanguage('lt', 'Lietuvių'),
  TranslationLanguage('lv', 'Latviešu'),
  TranslationLanguage('nb', 'Norsk bokmål'),
  TranslationLanguage('nl', 'Nederlands'),
  TranslationLanguage('pl', 'Polski'),
  TranslationLanguage('pt', 'Português'),
  TranslationLanguage('pt-BR', 'Português (Brasil)'),
  TranslationLanguage('pt-PT', 'Português (Portugal)'),
  TranslationLanguage('ro', 'Română'),
  TranslationLanguage('ru', 'Русский'),
  TranslationLanguage('sk', 'Slovenčina'),
  TranslationLanguage('sl', 'Slovenščina'),
  TranslationLanguage('sq', 'Shqip'),
  TranslationLanguage('sr', 'Српски'),
  TranslationLanguage('sv', 'Svenska'),
  TranslationLanguage('ta', 'தமிழ்'),
  TranslationLanguage('te', 'తెలుగు'),
  TranslationLanguage('th', 'ไทย'),
  TranslationLanguage('tr', 'Türkçe'),
  TranslationLanguage('uk', 'Українська'),
  TranslationLanguage('uz', 'Oʻzbekcha'),
  TranslationLanguage('vi', 'Tiếng Việt'),
  TranslationLanguage('yue', '粵語'),
  TranslationLanguage('zh', '中文（简体）'),
  TranslationLanguage('zh-Hant', '中文（繁體）'),
];

bool isTranslationLanguage(String code) =>
    translationLanguages.any((language) => language.code == code);

bool isTranslationTargetLanguage(String code) =>
    code == systemTranslationLanguageCode || isTranslationLanguage(code);

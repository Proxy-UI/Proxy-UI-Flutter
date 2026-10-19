/// Where countries are and what they are called, for placing node systems on
/// the galaxy map and naming them in both supported languages.
///
/// Coordinates are approximate geographic centres. They only decide which
/// systems sit next to each other, so a degree either way changes nothing.
library;

/// One country or territory.
class CountryInfo {
  const CountryInfo(this.code, this.lat, this.lon, this.english, this.chinese);

  /// ISO 3166-1 alpha-2, upper case.
  final String code;

  /// Latitude in degrees, north positive.
  final double lat;

  /// Longitude in degrees, east positive.
  final double lon;

  final String english;
  final String chinese;

  /// The name in [languageCode], English unless it is Chinese.
  String nameFor(String languageCode) =>
      languageCode == 'zh' ? chinese : english;
}

/// The country for [code], or null when it is unknown or empty.
CountryInfo? countryInfo(String code) {
  final key = normalizeCountryCode(code);
  if (key.isEmpty) return null;
  final row = _atlas[key];
  if (row == null) return null;
  return CountryInfo(key, row.$1, row.$2, row.$3, row.$4);
}

/// [code] as a two-letter upper-case code, or empty when it is not one.
///
/// The catalogue sometimes carries free text such as `US - Virginia`; the
/// first two-letter word is the code.
String normalizeCountryCode(String code) {
  final trimmed = code.trim().toUpperCase();
  if (trimmed.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(trimmed)) {
    if (trimmed == 'UK') return 'GB';
    return trimmed;
  }
  final match = RegExp(r'\b([A-Z]{2})\b').firstMatch(trimmed);
  final found = match?.group(1) ?? '';
  return found == 'UK' ? 'GB' : found;
}

/// The display name of [code] in [languageCode]; the code itself when the
/// atlas does not know it.
String countryName(String code, String languageCode) =>
    countryInfo(code)?.nameFor(languageCode) ?? normalizeCountryCode(code);

const Map<String, (double, double, String, String)> _atlas = {
  'AD': (42.5, 1.5, 'Andorra', '安道尔'),
  'AE': (24.0, 54.0, 'United Arab Emirates', '阿联酋'),
  'AF': (33.9, 67.7, 'Afghanistan', '阿富汗'),
  'AG': (17.1, -61.8, 'Antigua and Barbuda', '安提瓜和巴布达'),
  'AL': (41.2, 20.2, 'Albania', '阿尔巴尼亚'),
  'AM': (40.1, 45.0, 'Armenia', '亚美尼亚'),
  'AO': (-11.2, 17.9, 'Angola', '安哥拉'),
  'AR': (-38.4, -63.6, 'Argentina', '阿根廷'),
  'AS': (-14.3, -170.7, 'American Samoa', '美属萨摩亚'),
  'AT': (47.5, 14.6, 'Austria', '奥地利'),
  'AU': (-25.3, 133.8, 'Australia', '澳大利亚'),
  'AW': (12.5, -70.0, 'Aruba', '阿鲁巴'),
  'AX': (60.2, 19.9, 'Åland Islands', '奥兰群岛'),
  'AZ': (40.1, 47.6, 'Azerbaijan', '阿塞拜疆'),
  'BA': (43.9, 17.7, 'Bosnia and Herzegovina', '波黑'),
  'BB': (13.2, -59.5, 'Barbados', '巴巴多斯'),
  'BD': (23.7, 90.4, 'Bangladesh', '孟加拉国'),
  'BE': (50.5, 4.5, 'Belgium', '比利时'),
  'BF': (12.2, -1.6, 'Burkina Faso', '布基纳法索'),
  'BG': (42.7, 25.5, 'Bulgaria', '保加利亚'),
  'BH': (26.0, 50.6, 'Bahrain', '巴林'),
  'BI': (-3.4, 29.9, 'Burundi', '布隆迪'),
  'BJ': (9.3, 2.3, 'Benin', '贝宁'),
  'BM': (32.3, -64.8, 'Bermuda', '百慕大'),
  'BN': (4.5, 114.7, 'Brunei', '文莱'),
  'BO': (-16.3, -63.6, 'Bolivia', '玻利维亚'),
  'BR': (-14.2, -51.9, 'Brazil', '巴西'),
  'BS': (25.0, -77.4, 'Bahamas', '巴哈马'),
  'BT': (27.5, 90.4, 'Bhutan', '不丹'),
  'BW': (-22.3, 24.7, 'Botswana', '博茨瓦纳'),
  'BY': (53.7, 28.0, 'Belarus', '白俄罗斯'),
  'BZ': (17.2, -88.5, 'Belize', '伯利兹'),
  'CA': (56.1, -106.3, 'Canada', '加拿大'),
  'CD': (-4.0, 21.8, 'DR Congo', '刚果（金）'),
  'CF': (6.6, 20.9, 'Central African Republic', '中非'),
  'CG': (-0.2, 15.8, 'Congo', '刚果（布）'),
  'CH': (46.8, 8.2, 'Switzerland', '瑞士'),
  'CI': (7.5, -5.5, "Côte d'Ivoire", '科特迪瓦'),
  'CL': (-35.7, -71.5, 'Chile', '智利'),
  'CM': (7.4, 12.4, 'Cameroon', '喀麦隆'),
  'CN': (35.9, 104.2, 'China', '中国'),
  'CO': (4.6, -74.3, 'Colombia', '哥伦比亚'),
  'CR': (9.7, -83.8, 'Costa Rica', '哥斯达黎加'),
  'CU': (21.5, -77.8, 'Cuba', '古巴'),
  'CV': (16.0, -24.0, 'Cape Verde', '佛得角'),
  'CW': (12.2, -69.0, 'Curaçao', '库拉索'),
  'CY': (35.1, 33.4, 'Cyprus', '塞浦路斯'),
  'CZ': (49.8, 15.5, 'Czechia', '捷克'),
  'DE': (51.2, 10.5, 'Germany', '德国'),
  'DJ': (11.8, 42.6, 'Djibouti', '吉布提'),
  'DK': (56.3, 9.5, 'Denmark', '丹麦'),
  'DM': (15.4, -61.4, 'Dominica', '多米尼克'),
  'DO': (18.7, -70.2, 'Dominican Republic', '多米尼加'),
  'DZ': (28.0, 1.7, 'Algeria', '阿尔及利亚'),
  'EC': (-1.8, -78.2, 'Ecuador', '厄瓜多尔'),
  'EE': (58.6, 25.0, 'Estonia', '爱沙尼亚'),
  'EG': (26.8, 30.8, 'Egypt', '埃及'),
  'ER': (15.2, 39.8, 'Eritrea', '厄立特里亚'),
  'ES': (40.5, -3.7, 'Spain', '西班牙'),
  'ET': (9.1, 40.5, 'Ethiopia', '埃塞俄比亚'),
  'FI': (61.9, 25.7, 'Finland', '芬兰'),
  'FJ': (-17.7, 178.1, 'Fiji', '斐济'),
  'FM': (7.4, 150.6, 'Micronesia', '密克罗尼西亚'),
  'FO': (61.9, -6.9, 'Faroe Islands', '法罗群岛'),
  'FR': (46.2, 2.2, 'France', '法国'),
  'GA': (-0.8, 11.6, 'Gabon', '加蓬'),
  'GB': (55.4, -3.4, 'United Kingdom', '英国'),
  'GD': (12.1, -61.7, 'Grenada', '格林纳达'),
  'GE': (42.3, 43.4, 'Georgia', '格鲁吉亚'),
  'GG': (49.5, -2.6, 'Guernsey', '根西岛'),
  'GH': (7.9, -1.0, 'Ghana', '加纳'),
  'GI': (36.1, -5.4, 'Gibraltar', '直布罗陀'),
  'GL': (71.7, -42.6, 'Greenland', '格陵兰'),
  'GM': (13.4, -15.3, 'Gambia', '冈比亚'),
  'GN': (9.9, -9.7, 'Guinea', '几内亚'),
  'GQ': (1.7, 10.3, 'Equatorial Guinea', '赤道几内亚'),
  'GR': (39.1, 21.8, 'Greece', '希腊'),
  'GT': (15.8, -90.2, 'Guatemala', '危地马拉'),
  'GU': (13.4, 144.8, 'Guam', '关岛'),
  'GW': (11.8, -15.2, 'Guinea-Bissau', '几内亚比绍'),
  'GY': (4.9, -58.9, 'Guyana', '圭亚那'),
  'HK': (22.3, 114.2, 'Hong Kong', '中国香港'),
  'HN': (15.2, -86.2, 'Honduras', '洪都拉斯'),
  'HR': (45.1, 15.2, 'Croatia', '克罗地亚'),
  'HT': (19.0, -72.3, 'Haiti', '海地'),
  'HU': (47.2, 19.5, 'Hungary', '匈牙利'),
  'ID': (-0.8, 113.9, 'Indonesia', '印度尼西亚'),
  'IE': (53.4, -8.2, 'Ireland', '爱尔兰'),
  'IL': (31.0, 34.9, 'Israel', '以色列'),
  'IM': (54.2, -4.5, 'Isle of Man', '马恩岛'),
  'IN': (20.6, 79.0, 'India', '印度'),
  'IQ': (33.2, 43.7, 'Iraq', '伊拉克'),
  'IR': (32.4, 53.7, 'Iran', '伊朗'),
  'IS': (65.0, -19.0, 'Iceland', '冰岛'),
  'IT': (41.9, 12.6, 'Italy', '意大利'),
  'JE': (49.2, -2.1, 'Jersey', '泽西岛'),
  'JM': (18.1, -77.3, 'Jamaica', '牙买加'),
  'JO': (30.6, 36.2, 'Jordan', '约旦'),
  'JP': (36.2, 138.3, 'Japan', '日本'),
  'KE': (0.0, 37.9, 'Kenya', '肯尼亚'),
  'KG': (41.2, 74.8, 'Kyrgyzstan', '吉尔吉斯斯坦'),
  'KH': (12.6, 104.9, 'Cambodia', '柬埔寨'),
  'KI': (1.9, -157.4, 'Kiribati', '基里巴斯'),
  'KM': (-11.9, 43.9, 'Comoros', '科摩罗'),
  'KN': (17.4, -62.8, 'Saint Kitts and Nevis', '圣基茨和尼维斯'),
  'KP': (40.3, 127.5, 'North Korea', '朝鲜'),
  'KR': (35.9, 127.8, 'South Korea', '韩国'),
  'KW': (29.3, 47.5, 'Kuwait', '科威特'),
  'KY': (19.3, -81.3, 'Cayman Islands', '开曼群岛'),
  'KZ': (48.0, 66.9, 'Kazakhstan', '哈萨克斯坦'),
  'LA': (19.9, 102.5, 'Laos', '老挝'),
  'LB': (33.9, 35.9, 'Lebanon', '黎巴嫩'),
  'LC': (13.9, -61.0, 'Saint Lucia', '圣卢西亚'),
  'LI': (47.2, 9.6, 'Liechtenstein', '列支敦士登'),
  'LK': (7.9, 80.8, 'Sri Lanka', '斯里兰卡'),
  'LR': (6.4, -9.4, 'Liberia', '利比里亚'),
  'LS': (-29.6, 28.2, 'Lesotho', '莱索托'),
  'LT': (55.2, 23.9, 'Lithuania', '立陶宛'),
  'LU': (49.8, 6.1, 'Luxembourg', '卢森堡'),
  'LV': (56.9, 24.6, 'Latvia', '拉脱维亚'),
  'LY': (26.3, 17.2, 'Libya', '利比亚'),
  'MA': (31.8, -7.1, 'Morocco', '摩洛哥'),
  'MC': (43.7, 7.4, 'Monaco', '摩纳哥'),
  'MD': (47.4, 28.4, 'Moldova', '摩尔多瓦'),
  'ME': (42.7, 19.4, 'Montenegro', '黑山'),
  'MG': (-18.8, 46.9, 'Madagascar', '马达加斯加'),
  'MH': (7.1, 171.2, 'Marshall Islands', '马绍尔群岛'),
  'MK': (41.6, 21.7, 'North Macedonia', '北马其顿'),
  'ML': (17.6, -4.0, 'Mali', '马里'),
  'MM': (21.9, 95.9, 'Myanmar', '缅甸'),
  'MN': (46.9, 103.8, 'Mongolia', '蒙古'),
  'MO': (22.2, 113.5, 'Macao', '中国澳门'),
  'MP': (15.1, 145.7, 'Northern Mariana Islands', '北马里亚纳群岛'),
  'MR': (21.0, -10.9, 'Mauritania', '毛里塔尼亚'),
  'MT': (35.9, 14.4, 'Malta', '马耳他'),
  'MU': (-20.3, 57.6, 'Mauritius', '毛里求斯'),
  'MV': (3.2, 73.2, 'Maldives', '马尔代夫'),
  'MW': (-13.3, 34.3, 'Malawi', '马拉维'),
  'MX': (23.6, -102.6, 'Mexico', '墨西哥'),
  'MY': (4.2, 102.0, 'Malaysia', '马来西亚'),
  'MZ': (-18.7, 35.5, 'Mozambique', '莫桑比克'),
  'NA': (-23.0, 18.5, 'Namibia', '纳米比亚'),
  'NC': (-20.9, 165.6, 'New Caledonia', '新喀里多尼亚'),
  'NE': (17.6, 8.1, 'Niger', '尼日尔'),
  'NG': (9.1, 8.7, 'Nigeria', '尼日利亚'),
  'NI': (12.9, -85.2, 'Nicaragua', '尼加拉瓜'),
  'NL': (52.1, 5.3, 'Netherlands', '荷兰'),
  'NO': (60.5, 8.5, 'Norway', '挪威'),
  'NP': (28.4, 84.1, 'Nepal', '尼泊尔'),
  'NR': (-0.5, 166.9, 'Nauru', '瑙鲁'),
  'NZ': (-40.9, 174.9, 'New Zealand', '新西兰'),
  'OM': (21.5, 55.9, 'Oman', '阿曼'),
  'PA': (8.5, -80.8, 'Panama', '巴拿马'),
  'PE': (-9.2, -75.0, 'Peru', '秘鲁'),
  'PF': (-17.7, -149.4, 'French Polynesia', '法属波利尼西亚'),
  'PG': (-6.3, 144.0, 'Papua New Guinea', '巴布亚新几内亚'),
  'PH': (12.9, 121.8, 'Philippines', '菲律宾'),
  'PK': (30.4, 69.3, 'Pakistan', '巴基斯坦'),
  'PL': (51.9, 19.1, 'Poland', '波兰'),
  'PR': (18.2, -66.6, 'Puerto Rico', '波多黎各'),
  'PS': (31.9, 35.2, 'Palestine', '巴勒斯坦'),
  'PT': (39.4, -8.2, 'Portugal', '葡萄牙'),
  'PW': (7.5, 134.6, 'Palau', '帕劳'),
  'PY': (-23.4, -58.4, 'Paraguay', '巴拉圭'),
  'QA': (25.4, 51.2, 'Qatar', '卡塔尔'),
  'RE': (-21.1, 55.5, 'Réunion', '留尼汪'),
  'RO': (45.9, 25.0, 'Romania', '罗马尼亚'),
  'RS': (44.0, 21.0, 'Serbia', '塞尔维亚'),
  'RU': (61.5, 105.3, 'Russia', '俄罗斯'),
  'RW': (-1.9, 29.9, 'Rwanda', '卢旺达'),
  'SA': (23.9, 45.1, 'Saudi Arabia', '沙特阿拉伯'),
  'SB': (-9.6, 160.2, 'Solomon Islands', '所罗门群岛'),
  'SC': (-4.7, 55.5, 'Seychelles', '塞舌尔'),
  'SD': (12.9, 30.2, 'Sudan', '苏丹'),
  'SE': (60.1, 18.6, 'Sweden', '瑞典'),
  'SG': (1.35, 103.8, 'Singapore', '新加坡'),
  'SI': (46.2, 15.0, 'Slovenia', '斯洛文尼亚'),
  'SK': (48.7, 19.7, 'Slovakia', '斯洛伐克'),
  'SL': (8.5, -11.8, 'Sierra Leone', '塞拉利昂'),
  'SM': (43.9, 12.5, 'San Marino', '圣马力诺'),
  'SN': (14.5, -14.5, 'Senegal', '塞内加尔'),
  'SO': (5.2, 46.2, 'Somalia', '索马里'),
  'SR': (3.9, -56.0, 'Suriname', '苏里南'),
  'SS': (6.9, 31.3, 'South Sudan', '南苏丹'),
  'ST': (0.2, 6.6, 'São Tomé and Príncipe', '圣多美和普林西比'),
  'SV': (13.8, -88.9, 'El Salvador', '萨尔瓦多'),
  'SY': (34.8, 39.0, 'Syria', '叙利亚'),
  'SZ': (-26.5, 31.5, 'Eswatini', '斯威士兰'),
  'TD': (15.5, 18.7, 'Chad', '乍得'),
  'TG': (8.6, 0.8, 'Togo', '多哥'),
  'TH': (15.9, 101.0, 'Thailand', '泰国'),
  'TJ': (38.9, 71.3, 'Tajikistan', '塔吉克斯坦'),
  'TL': (-8.9, 125.7, 'Timor-Leste', '东帝汶'),
  'TM': (39.0, 59.6, 'Turkmenistan', '土库曼斯坦'),
  'TN': (33.9, 9.5, 'Tunisia', '突尼斯'),
  'TO': (-21.2, -175.2, 'Tonga', '汤加'),
  'TR': (39.0, 35.2, 'Türkiye', '土耳其'),
  'TT': (10.7, -61.2, 'Trinidad and Tobago', '特立尼达和多巴哥'),
  'TV': (-7.1, 177.6, 'Tuvalu', '图瓦卢'),
  'TW': (23.7, 121.0, 'Taiwan', '中国台湾'),
  'TZ': (-6.4, 34.9, 'Tanzania', '坦桑尼亚'),
  'UA': (48.4, 31.2, 'Ukraine', '乌克兰'),
  'UG': (1.4, 32.3, 'Uganda', '乌干达'),
  'US': (37.1, -95.7, 'United States', '美国'),
  'UY': (-32.5, -55.8, 'Uruguay', '乌拉圭'),
  'UZ': (41.4, 64.6, 'Uzbekistan', '乌兹别克斯坦'),
  'VA': (41.9, 12.5, 'Vatican City', '梵蒂冈'),
  'VC': (13.0, -61.3, 'Saint Vincent and the Grenadines', '圣文森特和格林纳丁斯'),
  'VE': (6.4, -66.6, 'Venezuela', '委内瑞拉'),
  'VG': (18.4, -64.6, 'British Virgin Islands', '英属维尔京群岛'),
  'VI': (18.3, -64.9, 'U.S. Virgin Islands', '美属维尔京群岛'),
  'VN': (14.1, 108.3, 'Vietnam', '越南'),
  'VU': (-15.4, 167.0, 'Vanuatu', '瓦努阿图'),
  'WS': (-13.8, -172.1, 'Samoa', '萨摩亚'),
  'XK': (42.6, 20.9, 'Kosovo', '科索沃'),
  'YE': (15.6, 48.5, 'Yemen', '也门'),
  'ZA': (-30.6, 22.9, 'South Africa', '南非'),
  'ZM': (-13.1, 27.8, 'Zambia', '赞比亚'),
  'ZW': (-19.0, 29.2, 'Zimbabwe', '津巴布韦'),
};

import Foundation

/// 全拼音节表（由雾凇 8105 字表的读音整理，共 414 个），只用来判断一串字母能不能整段拼成拼音：
/// 中英混输时，能拼成拼音就让中文排在前面、英文单词放到这一页末尾。
/// Mac 输入法（InputSession）和 iOS 键盘（KeyboardSession）共用，所以放在 iOS 也编译的 KeyiIMETranslation 里。
public enum KeyiPinyinSyllables {
    public static let all: Set<String> = [
        "a", "ai", "an", "ang", "ao", "ba", "bai", "ban", "bang", "bao", "bei", "ben",
        "beng", "bi", "bian", "biang", "biao", "bie", "bin", "bing", "bo", "bu", "ca", "cai",
        "can", "cang", "cao", "ce", "cei", "cen", "ceng", "cha", "chai", "chan", "chang", "chao",
        "che", "chen", "cheng", "chi", "chong", "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui",
        "chun", "chuo", "ci", "cong", "cou", "cu", "cuan", "cui", "cun", "cuo", "da", "dai",
        "dan", "dang", "dao", "de", "dei", "den", "deng", "di", "dia", "dian", "diao", "die",
        "ding", "diu", "dong", "dou", "du", "duan", "dui", "dun", "duo", "e", "ei", "en",
        "eng", "er", "fa", "fan", "fang", "fei", "fen", "feng", "fiao", "fo", "fou", "fu",
        "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong", "gou", "gu",
        "gua", "guai", "guan", "guang", "gui", "gun", "guo", "ha", "hai", "han", "hang", "hao",
        "he", "hei", "hen", "heng", "hong", "hou", "hu", "hua", "huai", "huan", "huang", "hui",
        "hun", "huo", "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing", "jiong", "jiu",
        "ju", "juan", "jue", "jun", "ka", "kai", "kan", "kang", "kao", "ke", "kei", "ken",
        "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang", "kui", "kun", "kuo", "la",
        "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia", "lian", "liang", "liao",
        "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lun", "luo", "lv",
        "lve", "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi", "mian",
        "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu", "na", "nai", "nan", "nang",
        "nao", "ne", "nei", "nen", "neng", "ni", "nian", "niang", "niao", "nie", "nin", "ning",
        "niu", "nong", "nou", "nu", "nuan", "nuo", "nv", "nve", "o", "ou", "pa", "pai",
        "pan", "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping",
        "po", "pou", "pu", "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong",
        "qiu", "qu", "quan", "que", "qun", "ran", "rang", "rao", "re", "ren", "reng", "ri",
        "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo", "sa", "sai", "san", "sang",
        "sao", "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen",
        "sheng", "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si",
        "song", "sou", "su", "suan", "sui", "sun", "suo", "ta", "tai", "tan", "tang", "tao",
        "te", "tei", "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan",
        "tui", "tun", "tuo", "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu",
        "xi", "xia", "xian", "xiang", "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan",
        "xue", "xun", "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong",
        "you", "yu", "yuan", "yue", "yun", "za", "zai", "zan", "zang", "zao", "ze", "zei",
        "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng", "zhi",
        "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo", "zi", "zong",
        "zou", "zu", "zuan", "zui", "zun", "zuo",
    ]

    /// `input` 去掉手动分隔符 `'` 后，每一段都能完整切成拼音音节。
    public static func spellsWholly(_ input: String) -> Bool {
        let parts = input.lowercased().split(separator: "'", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let letters = Array(part)
            guard letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
            var reachable = [Bool](repeating: false, count: letters.count + 1)
            reachable[0] = true
            for start in 0..<letters.count where reachable[start] {
                for end in (start + 1)...min(letters.count, start + 6)
                where all.contains(String(letters[start..<end])) {
                    reachable[end] = true
                }
            }
            return reachable[letters.count]
        }
    }

    /// 中英混输：Rime 把英文单词排在前面。英文有两种：正好是打的字母的单词（model），和打的字母
    /// 开头的常用词联想（wo → would、work，英文词表的 `english/hint`）。
    /// - 打的字母整段能拼成拼音时（wo、men、change）用户多半在打中文：中文在前，单词、联想放这一页末尾。
    /// - 拼不成拼音时（model、github）单词排第一；三个字母以上（wou、bec）联想紧跟着，排在中文前面；
    ///   只有两个字母（sh）时联想放末尾，简拼的中文在前。
    /// 返回 `result[显示位置] = Rime 页内位置`，不用调整时为 nil。
    public static func mixedEnglishOrder(_ candidates: [String], input: String) -> [Int]? {
        let latin = candidates.map { $0.unicodeScalars.allSatisfy(\.isASCII) }
        guard latin.contains(true) else { return nil }
        let typed = englishLetters(input)
        let exact = candidates.indices.filter { latin[$0] && englishLetters(candidates[$0]) == typed }
        let hints = candidates.indices.filter { latin[$0] && !exact.contains($0) }
        let chinese = candidates.indices.filter { !latin[$0] }
        let order: [Int]
        if spellsWholly(input) {
            order = chinese + exact + hints
        } else if typed.count >= 3 {
            order = exact + hints + chinese
        } else {
            order = exact + chinese + hints
        }
        return order == Array(candidates.indices) ? nil : order
    }

    /// 英文单词按打的字母比较：去掉符号、统一小写（Node.js → nodejs，GitHub → github）。
    static func englishLetters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }
}

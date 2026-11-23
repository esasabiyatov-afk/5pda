import Foundation
import UIKit

/// Смайлы 4PDA (коды и картинки из Android-клиента).
enum Smilies {
    struct Smile: Decodable { let code: String; let img: String; let w: Int; let h: Int; let hidden: Bool }

    static let all: [Smile] = {
        guard let url = Bundle.main.url(forResource: "smilies", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Smile].self, from: data) else { return [] }
        return list
    }()

    /// Для панели выбора — по одному на картинку, без скрытых.
    static let picker: [Smile] = {
        var seen = Set<String>()
        return all.filter { !$0.hidden && seen.insert($0.img).inserted }
    }()

    /// Коды по убыванию длины — чтобы «:-)» находился раньше «:)».
    private static let sorted: [Smile] = all.sorted { $0.code.count > $1.code.count }
    private static let firstChars: Set<Character> = Set(all.compactMap { $0.code.first })

    private static var imageCache: [String: UIImage] = [:]
    /// Картинка смайла в размере, заданном в клиенте (в точках).
    static func image(_ name: String) -> UIImage? {
        if let i = imageCache[name] { return i }
        guard let raw = UIImage(named: name) else { return nil }
        let size = self.size(name)
        let i = UIGraphicsImageRenderer(size: size).image { _ in raw.draw(in: CGRect(origin: .zero, size: size)) }
        imageCache[name] = i
        return i
    }

    static func size(_ name: String) -> CGSize {
        guard let s = all.first(where: { $0.img == name }) else { return CGSize(width: 18, height: 18) }
        return CGSize(width: s.w, height: s.h)
    }

    enum Piece { case text(String), smile(Smile) }

    /// Делит текст на обычные куски и смайлы. Смайл распознаётся, если перед ним
    /// пробел/начало строки (как на форуме), чтобы не ломать ссылки и код.
    static func split(_ s: String) -> [Piece] {
        guard !all.isEmpty, s.contains(where: { firstChars.contains($0) }) else { return [.text(s)] }
        var out: [Piece] = []
        var buf = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let prevOK = i == s.startIndex || s[s.index(before: i)].isWhitespace || s[s.index(before: i)].isPunctuation
            if firstChars.contains(c), prevOK,
               let m = sorted.first(where: { s[i...].hasPrefix($0.code) }) {
                if !buf.isEmpty { out.append(.text(buf)); buf = "" }
                out.append(.smile(m))
                i = s.index(i, offsetBy: m.code.count)
                continue
            }
            buf.append(c)
            i = s.index(after: i)
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }
}

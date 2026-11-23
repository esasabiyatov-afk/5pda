import SwiftUI

/// Цвета и оформление из ресурсов Android-клиента (res/values/colors.xml).
enum PDATheme {
    /// Синий шапки 4PDA.
    static let brand = Color(red: 0x19 / 255, green: 0x76 / 255, blue: 0xD2 / 255)
    /// Полоса спойлера/цитаты.
    static let spoilerBar = Color(red: 0x4A / 255, green: 0x90 / 255, blue: 0xE2 / 255)
    static let online = Color(red: 0x6A / 255, green: 0xA8 / 255, blue: 0x3F / 255)
    static let unreadDot = Color(red: 0x6A / 255, green: 0xA8 / 255, blue: 0x3F / 255)

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Цвет группы пользователя (group_* из colors.xml).
    static func groupColor(_ group: Int) -> Color {
        switch group {
        case 3, 7: return hex(0x008000)      // пользователи, активные
        case 4: return hex(0xFF0000)         // админы
        case 5, 1, 2: return hex(0xA0A0A0)   // забанен, неактивированные, гости
        case 8: return hex(0xFF9900)         // друзья 4PDA
        case 9, 11, 19: return hex(0x0099FF) // модераторы, помощники, школа
        case 10: return hex(0x0000FF)        // супермодераторы
        case 12: return hex(0x32CD32)        // FAQMakers
        case 13: return hex(0x800080)        // почётные
        case 15: return hex(0xBC33FF)        // разработчики
        case 16: return .primary             // роутеры
        case 17: return hex(0xB100BF)        // бизнесмены
        case 18: return hex(0x9A60FF)        // спецпроект
        case 20: return hex(0x008B8B)        // кураторы
        default: return .secondary
        }
    }
}

/// Аватар как в Android: квадрат со скруглением.
struct AvatarView: View {
    let url: String
    var size: CGFloat = 44

    var body: some View {
        RemoteImage(avatar: PDAAPI.absoluteURL(url))
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

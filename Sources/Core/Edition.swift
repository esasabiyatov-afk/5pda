import Foundation

/// Вариант приложения: обычный 5PDA (порт Android-клиента) или 5PDA X (мод с
/// интерфейсом, удобным для iOS). Общий код один, различия — по флагу FIVEPDA_X.
enum Edition {
    #if FIVEPDA_X
    static let isX = true
    static let name = "5PDA X"
    #else
    static let isX = false
    static let name = "5PDA"
    #endif
}

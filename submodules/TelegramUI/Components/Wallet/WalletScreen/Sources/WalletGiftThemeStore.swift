import Foundation

private struct WalletGiftThemeStoredValue<Value: Codable>: Codable {
    let version: Int
    let value: Value
}

/// Cosmetic preferences live separately from wallet keys and transaction state.
final class WalletGiftThemeStore<Value: Codable> {
    private let defaults: UserDefaults
    private let key: String
    private let maximumDataSize = 1024 * 1024

    init(accountId: Int64, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = "telegram.walletGiftTheme.v1.\(accountId)"
    }

    func load() -> Value? {
        guard let data = self.defaults.data(forKey: self.key), data.count <= self.maximumDataSize,
              let stored = try? JSONDecoder().decode(WalletGiftThemeStoredValue<Value>.self, from: data),
              stored.version == 1 else {
            return nil
        }
        return stored.value
    }

    @discardableResult
    func save(_ value: Value?) -> Bool {
        guard let value else {
            self.defaults.removeObject(forKey: self.key)
            return true
        }
        guard let data = try? JSONEncoder().encode(WalletGiftThemeStoredValue(version: 1, value: value)),
              data.count <= self.maximumDataSize else {
            return false
        }
        self.defaults.set(data, forKey: self.key)
        return true
    }
}

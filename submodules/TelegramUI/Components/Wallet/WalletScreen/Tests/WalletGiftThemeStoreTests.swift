import Foundation

private struct GiftThemeFixture: Codable, Equatable {
    struct Artwork: Codable, Equatable {
        let fileId: Int64
        let resource: String
    }

    let giftId: Int64
    let title: String
    let model: Artwork
    let pattern: Artwork?
    let colors: [UInt32]
    var padding: String = ""
}

private struct UnencodableTheme: Codable {
    enum Failure: Error {
        case intentional
    }

    init() {
    }

    init(from decoder: Decoder) throws {
        throw Failure.intentional
    }

    func encode(to encoder: Encoder) throws {
        throw Failure.intentional
    }
}

@main
private enum WalletGiftThemeStoreTests {
    static func main() throws {
        let suiteName = "WalletGiftThemeStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create an isolated preferences suite")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() {
                fatalError(message)
            }
        }
        func storedKey(for accountId: Int64) -> String {
            let keys = defaults.persistentDomain(forName: suiteName)?.keys.filter {
                $0.hasSuffix(".\(accountId)") && $0.contains("walletGiftTheme")
            } ?? []
            check(keys.count == 1, "Each account must have one distinct theme key")
            return keys.first!
        }

        let gift = GiftThemeFixture(
            giftId: Int64.max,
            title: "Gift 🌟 / Подарок",
            model: .init(fileId: 123, resource: "model-file"),
            pattern: .init(fileId: 456, resource: "pattern-file"),
            colors: [0xffffff, 0, 0x8040ff]
        )
        let otherGift = GiftThemeFixture(
            giftId: 2,
            title: "Other Gift",
            model: .init(fileId: 789, resource: "other-model"),
            pattern: nil,
            colors: [0x112233, 0x445566]
        )
        let accountOne = WalletGiftThemeStore<GiftThemeFixture>(accountId: 1, defaults: defaults)
        let accountTwo = WalletGiftThemeStore<GiftThemeFixture>(accountId: 2, defaults: defaults)
        check(accountOne.load() == nil, "A new account starts with the default card")
        check(accountOne.save(gift), "A valid visual snapshot should save")
        check(accountOne.load() == gift, "A saved gift preserves Unicode, media references, and colors")
        check(accountTwo.load() == nil, "A second account must not inherit the first account's gift")
        check(accountTwo.save(otherGift), "The second account can save its own gift")
        check(accountOne.load() == gift && accountTwo.load() == otherGift, "Account preferences stay independent")
        check(WalletGiftThemeStore<GiftThemeFixture>(accountId: 1, defaults: defaults).load() == gift, "Recreating the store preserves the chosen theme")

        defaults.set("untouched", forKey: "unrelated.preference")
        check(accountOne.save(nil), "Restoring the default card should succeed")
        check(accountOne.load() == nil, "Default restoration removes the selected snapshot")
        check(accountTwo.load() == otherGift, "Restoring one account must not affect another")
        check(defaults.string(forKey: "unrelated.preference") == "untouched", "Theme restoration preserves unrelated settings")
        check(WalletGiftThemeStore<GiftThemeFixture>(accountId: 1, defaults: defaults).load() == nil, "Default restoration survives relaunch")

        for accountId in [Int64.min, -1, 0, Int64.max] {
            let store = WalletGiftThemeStore<GiftThemeFixture>(accountId: accountId, defaults: defaults)
            check(store.load() == nil, "Signed account record IDs have separate keys")
            check(store.save(gift), "Extreme account record IDs should save")
            check(store.load() == gift, "Extreme account record IDs should reload")
        }
        check(accountTwo.load() == otherGift, "Extreme IDs do not collide with ordinary accounts")

        check(accountOne.save(gift), "Restore a valid fixture before corruption checks")
        let key = storedKey(for: 1)
        let validData = defaults.data(forKey: key)!
        defaults.set(Data("not-json".utf8), forKey: key)
        check(accountOne.load() == nil, "Corrupt data safely falls back to the default card")
        defaults.set("wrong preferences type", forKey: key)
        check(accountOne.load() == nil, "Wrong preferences types safely fall back")

        var object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        object["version"] = 99
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        check(accountOne.load() == nil, "An unsupported schema must not interpret a gift incorrectly")
        object.removeValue(forKey: "version")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        check(accountOne.load() == nil, "A missing schema version is rejected")
        object["version"] = 1
        object["value"] = ["giftId": 3]
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        check(accountOne.load() == nil, "An incomplete gift snapshot is rejected")

        object = try JSONSerialization.jsonObject(with: validData) as! [String: Any]
        object["futureOptionalMetadata"] = ["flag": true]
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        check(accountOne.load() == gift, "Unknown optional envelope fields preserve a valid gift")

        let maximumDataSize = 1024 * 1024
        defaults.set(Data(repeating: 0x20, count: maximumDataSize + 1), forKey: key)
        check(accountOne.load() == nil, "Oversized stored data is rejected before decoding")
        check(accountOne.save(gift), "A valid save can replace corrupt data")
        let beforeOversizedSave = defaults.data(forKey: key)
        var oversizedGift = gift
        oversizedGift.padding = String(repeating: "x", count: maximumDataSize)
        check(!accountOne.save(oversizedGift), "An oversized gift must fail to save")
        check(defaults.data(forKey: key) == beforeOversizedSave, "A failed save preserves the previous theme")
        check(accountOne.load() == gift, "A failed save keeps the previous gift usable")

        var boundaryGift = gift
        boundaryGift.padding = String(repeating: "x", count: maximumDataSize - beforeOversizedSave!.count)
        check(accountOne.save(boundaryGift), "The exact size boundary is accepted")
        check(defaults.data(forKey: key)?.count == maximumDataSize, "The boundary fixture exercises the exact stored byte limit")
        check(accountOne.load() == boundaryGift, "An accepted boundary snapshot can reload")
        boundaryGift.padding.append("x")
        check(!accountOne.save(boundaryGift), "One byte over the size boundary is rejected")
        check(defaults.data(forKey: key)?.count == maximumDataSize, "A rejected boundary save preserves the valid snapshot")

        let failingStore = WalletGiftThemeStore<UnencodableTheme>(accountId: 1, defaults: defaults)
        let beforeFailedEncoding = defaults.data(forKey: key)
        check(!failingStore.save(UnencodableTheme()), "Serialization errors should return failure")
        check(defaults.data(forKey: key) == beforeFailedEncoding, "Serialization errors must not overwrite preferences")
        check(accountOne.save(nil), "Default restoration also clears a large snapshot")
        check(defaults.object(forKey: key) == nil, "Default restoration removes the key entirely")
        check(accountTwo.load() == otherGift, "Corruption and size checks remain isolated to the tested account")

        print("Wallet gift theme store: \(assertions) assertions passed")
    }
}

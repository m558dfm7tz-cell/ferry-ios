import Foundation

/// A saved server shortcut. Credentials stay exclusively in Keychain under
/// the endpoint origin; this record deliberately contains no password/token.
struct SavedComputer: Codable, Identifiable, Equatable {
    var origin: String
    var name: String
    var id: String { origin }
}

import Foundation

/// The guest name rule shared by the owner's share sheet and the guest's invite check.
/// Mirrors the daemon: `^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$`.
public enum GuestName {
    public static let maxLength = 32

    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maxLength, isAlnum(first) else { return false }
        return bytes.dropFirst().allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// The prefix the host daemon puts on every guest prompt.
    public static func label(_ name: String) -> String {
        "\(name) (via HerdrUp): "
    }

    private static func isAlnum(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

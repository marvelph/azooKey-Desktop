public struct KeyEventCore: Sendable, Equatable {
    public struct ModifierFlag: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift   = ModifierFlag(rawValue: 1 << 0)
        public static let control = ModifierFlag(rawValue: 1 << 1)
        public static let option  = ModifierFlag(rawValue: 1 << 2)
        public static let command = ModifierFlag(rawValue: 1 << 3)
    }

    public init(modifierFlags: ModifierFlag, characters: String?, charactersIgnoringModifiers: String?, keyCode: UInt16) {
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.keyCode = keyCode
    }
    var modifierFlags: ModifierFlag
    var characters: String?
    var charactersIgnoringModifiers: String?
    var keyCode: UInt16

    public var unmodifiedKeypadText: String? {
        guard modifierFlags.isSubset(of: [.shift]) else { return nil }
        switch keyCode {
        case 0x41: return "."
        case 0x43: return "*"
        case 0x45: return "+"
        case 0x4B: return "/"
        case 0x4E: return "-"
        case 0x51: return "="
        case 0x52: return "0"
        case 0x53: return "1"
        case 0x54: return "2"
        case 0x55: return "3"
        case 0x56: return "4"
        case 0x57: return "5"
        case 0x58: return "6"
        case 0x59: return "7"
        case 0x5B: return "8"
        case 0x5C: return "9"
        case 0x5F: return ","
        default: return nil
        }
    }
}

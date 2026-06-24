import Foundation

enum DSCPMark {
    static func name(for value: Int) -> String {
        switch value {
        case 0: return "Default"
        case 8: return "CS1"
        case 10: return "AF11"
        case 12: return "AF12"
        case 14: return "AF13"
        case 16: return "CS2"
        case 18: return "AF21"
        case 20: return "AF22"
        case 22: return "AF23"
        case 24: return "CS3"
        case 26: return "AF31"
        case 28: return "AF32"
        case 30: return "AF33"
        case 32: return "CS4"
        case 34: return "AF41"
        case 36: return "AF42"
        case 38: return "AF43"
        case 40: return "CS5"
        case 46: return "EF"
        case 48: return "CS6"
        case 56: return "CS7"
        default: return "Custom"
        }
    }
}

import Foundation

public enum ID3v2TextEncoding {

    static func decode(_ data: Data, encoding: UInt8) -> String {
        switch encoding {
        case 0:
            return String(data: data, encoding: .isoLatin1) ?? ""
        case 1:
            let bytes = Array(data)
            if bytes.count >= 2 {
                if bytes[0] == 0xFF, bytes[1] == 0xFE {
                    return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
                }
                if bytes[0] == 0xFE, bytes[1] == 0xFF {
                    return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
                }
            }
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        case 2:
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        case 3:
            return String(data: data, encoding: .utf8) ?? ""
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    static func encode(_ string: String, encoding: UInt8) -> Data {
        switch encoding {
        case 0:
            return string.data(using: .isoLatin1) ?? Data(string.utf8)
        case 1:
            var out = Data([0xFF, 0xFE])
            if let body = string.data(using: .utf16LittleEndian) {
                out.append(body)
            }
            return out
        case 2:
            return string.data(using: .utf16BigEndian) ?? Data()
        case 3:
            return Data(string.utf8)
        default:
            return Data(string.utf8)
        }
    }
}

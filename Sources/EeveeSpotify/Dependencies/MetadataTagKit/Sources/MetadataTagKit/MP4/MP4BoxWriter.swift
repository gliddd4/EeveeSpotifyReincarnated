import Foundation

internal enum MP4BoxWriter {
    static func box(type: String, payload: Data) -> Data {
        let total = payload.count + 8
        var out = Data()
        if total <= Int(UInt32.max) {
            out.append(uInt32BE(UInt32(total)))
        } else {
            out.append(uInt32BE(1))
            out.append(uInt64BE(UInt64(total + 8)))
        }
        out.append(typeBytes(type))
        out.append(payload)
        return out
    }

    static func dataBox(typeIndicator: UInt32, payload: Data) -> Data {
        var body = Data()
        body.append(uInt32BE(typeIndicator))
        body.append(uInt32BE(0))
        body.append(payload)
        return box(type: "data", payload: body)
    }

    static func uInt32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    static func uInt64BE(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func typeBytes(_ type: String) -> Data {
        type.data(using: .isoLatin1) ?? Data()
    }
}

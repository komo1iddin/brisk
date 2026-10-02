import Foundation

/// The two shapes H.264 comes in. WhatsApp carries Annex-B (each NAL unit
/// after a `00 00 01` or `00 00 00 01` start code); VideoToolbox makes and
/// takes AVCC (each unit after its length, four bytes big-endian).
nonisolated enum H264 {
    enum Unit: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case delimiter = 9
    }

    /// The unit's type, from its header byte.
    static func type(of unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1F
    }

    /// The NAL units of an Annex-B access unit, without their start codes.
    static func units(annexB data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    // A four-byte start code leaves its first zero behind.
                    var end = index
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start ..< end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }

    /// Annex-B from units.
    static func annexB(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(unit)
        }
        return out
    }

    /// The units of an AVCC buffer with four-byte lengths.
    static func units(avcc data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var index = 0
        while index + 4 <= bytes.count {
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 4
            guard length > 0, index + length <= bytes.count else { break }
            units.append(Data(bytes[index ..< index + length]))
            index += length
        }
        return units
    }

    /// AVCC from units.
    static func avcc(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}

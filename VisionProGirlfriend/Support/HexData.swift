import Foundation

extension Data {
    /// MiniMax 的音频字段是 **hex 编码**（不是 base64），这里自己解。
    init?(hexEncoded string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count % 2 == 0, !bytes.isEmpty else { return nil }

        var data = Data(capacity: bytes.count / 2)
        data.reserveCapacity(bytes.count / 2)

        var index = 0
        while index < bytes.count {
            guard let high = Data.hexNibble(bytes[index]),
                  let low = Data.hexNibble(bytes[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        self = data
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30          // 0-9
        case 0x61...0x66: return byte - 0x61 + 10     // a-f
        case 0x41...0x46: return byte - 0x41 + 10     // A-F
        default: return nil
        }
    }
}

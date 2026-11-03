import CryptoKit
import Foundation

/// Just enough RFC 6455 for Panes Web: the upgrade handshake, and binary
/// messages that each carry one Wire frame. Clients mask what they send;
/// servers don't.
enum WebSocket {
    enum Opcode: UInt8 { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

    /// The Sec-WebSocket-Accept value for a client's Sec-WebSocket-Key.
    static func acceptKey(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    static func frame(_ opcode: Opcode, _ payload: Data, mask: [UInt8]? = nil) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126: out.append(maskBit | UInt8(payload.count))
        case ..<65_536:
            out.append(maskBit | 126)
            out.append(contentsOf: UInt16(payload.count).bigEndianBytes)
        default:
            out.append(maskBit | 127)
            out.append(contentsOf: UInt64(payload.count).bigEndianBytes)
        }
        if let mask {
            out.append(contentsOf: mask)
            out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        } else {
            out.append(payload)
        }
        return out
    }

    /// Collects bytes and returns whole messages (fragments joined, masks removed).
    struct Reader {
        private var buffer = Data()
        private var fragments = Data()
        private var fragmentOpcode: Opcode?
        let maxMessage: Int

        enum Failure: Error { case tooLarge, badOpcode, unmasked }

        init(maxMessage: Int = Wire.maxPayload + 5) { self.maxMessage = maxMessage }

        mutating func push(_ bytes: Data, requireMask: Bool = true) throws -> [(Opcode, Data)] {
            buffer.append(bytes)
            var messages: [(Opcode, Data)] = []
            while true {
                let b = [UInt8](buffer.prefix(14))
                guard b.count >= 2 else { break }
                let fin = b[0] & 0x80 != 0
                guard let opcode = Opcode(rawValue: b[0] & 0x0F) else { throw Failure.badOpcode }
                let masked = b[1] & 0x80 != 0
                if requireMask && !masked { throw Failure.unmasked }
                var length = Int(b[1] & 0x7F), at = 2
                if length == 126 {
                    guard b.count >= 4 else { break }
                    length = Int(b[2]) << 8 | Int(b[3]); at = 4
                } else if length == 127 {
                    guard b.count >= 10 else { break }
                    length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }; at = 10
                }
                guard length <= maxMessage, fragments.count + length <= maxMessage else { throw Failure.tooLarge }
                let maskKey: [UInt8]
                if masked {
                    guard b.count >= at + 4 else { break }
                    maskKey = Array(b[at..<at + 4]); at += 4
                } else {
                    maskKey = []
                }
                guard buffer.count >= at + length else { break }
                let start = buffer.startIndex + at
                var payload = [UInt8](buffer[start..<start + length])
                if masked { for i in payload.indices { payload[i] ^= maskKey[i % 4] } }
                buffer = buffer.subdata(in: start + length..<buffer.endIndex)

                switch opcode {
                case .close, .ping, .pong:
                    messages.append((opcode, Data(payload)))   // control frames are never fragmented
                case .continuation:
                    fragments.append(contentsOf: payload)
                    if fin, let first = fragmentOpcode {
                        messages.append((first, fragments))
                        fragments = Data(); fragmentOpcode = nil
                    }
                case .text, .binary:
                    if fin {
                        messages.append((opcode, Data(payload)))
                    } else {
                        fragmentOpcode = opcode
                        fragments = Data(payload)
                    }
                }
            }
            return messages
        }
    }
}

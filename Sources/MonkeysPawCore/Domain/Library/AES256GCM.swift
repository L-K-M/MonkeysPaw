import Foundation

/// FIPS 197 AES-256 with SP 800-38D GCM (96-bit nonce, 128-bit tag) for the
/// §26 provider-settings payload. No OS crypto API; encryption is CTR-mode
/// only, so sealing and opening share one block direction.
enum AES256GCM {
    static let nonceBytes = 12
    static let tagBytes = 16
    static let keyBytes = 32

    /// Returns ciphertext ‖ tag. `nonce` must be fresh for every seal.
    static func seal(key: [UInt8], nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        let schedule = Schedule(key: key)
        let ciphertext = crypt(schedule, nonce: nonce, input: plaintext)
        let tag = authenticate(schedule, nonce: nonce, aad: aad, ciphertext: ciphertext)
        return ciphertext + tag
    }

    /// Authenticates and returns the plaintext, or nil on any mismatch.
    static func open(key: [UInt8], nonce: [UInt8], aad: [UInt8], sealed: [UInt8]) -> [UInt8]? {
        guard sealed.count >= tagBytes else { return nil }
        let ciphertext = Array(sealed.dropLast(tagBytes))
        let schedule = Schedule(key: key)
        let expected = authenticate(schedule, nonce: nonce, aad: aad, ciphertext: ciphertext)
        var difference = 0
        for index in 0..<tagBytes { difference |= Int(expected[index] ^ sealed[sealed.count - tagBytes + index]) }
        guard difference == 0 else { return nil }
        return crypt(schedule, nonce: nonce, input: ciphertext)
    }

    /// CTR over a 32-bit big-endian counter seeded by inc32(J0).
    private static func crypt(_ schedule: Schedule, nonce: [UInt8], input: [UInt8]) -> [UInt8] {
        var counter = Array(nonce) + [0, 0, 0, 1]
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        for block in stride(from: 0, to: input.count, by: 16) {
            increment(&counter)
            let mask = schedule.encrypt(counter)
            for index in 0..<min(16, input.count - block) {
                output.append(input[block + index] ^ mask[index])
            }
        }
        return output
    }

    private static func authenticate(_ schedule: Schedule, nonce: [UInt8], aad: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        let h = schedule.encrypt([UInt8](repeating: 0, count: 16))
        var x = [UInt8](repeating: 0, count: 16)
        for block in paddedBlocks(aad) + paddedBlocks(ciphertext) {
            for index in 0..<16 { x[index] ^= block[index] }
            multiply(&x, by: h)
        }
        var lengths = [UInt8](repeating: 0, count: 16)
        for shift in stride(from: 56, through: 0, by: -8) {
            lengths[7 - shift / 8] = UInt8(truncatingIfNeeded: UInt64(aad.count * 8) >> shift)
            lengths[15 - shift / 8] = UInt8(truncatingIfNeeded: UInt64(ciphertext.count * 8) >> shift)
        }
        for index in 0..<16 { x[index] ^= lengths[index] }
        multiply(&x, by: h)
        let mask = schedule.encrypt(Array(nonce) + [0, 0, 0, 1])
        return (0..<16).map { x[$0] ^ mask[$0] }
    }

    private static func paddedBlocks(_ data: [UInt8]) -> [[UInt8]] {
        var blocks: [[UInt8]] = []
        for block in stride(from: 0, to: data.count, by: 16) {
            var bytes = [UInt8](repeating: 0, count: 16)
            for index in 0..<min(16, data.count - block) { bytes[index] = data[block + index] }
            blocks.append(bytes)
        }
        return blocks
    }

    /// GF(2^128) multiplication modulo x^128+x^7+x^2+x+1 (SP 800-38D 6.3).
    private static func multiply(_ x: inout [UInt8], by y: [UInt8]) {
        var z = [UInt8](repeating: 0, count: 16)
        var v = y
        for byte in x {
            for bit in (0..<8).reversed() {
                if byte & (1 << bit) != 0 { for index in 0..<16 { z[index] ^= v[index] } }
                let low = v[15] & 1
                for index in stride(from: 15, through: 1, by: -1) { v[index] = (v[index] >> 1) | (v[index - 1] << 7) }
                v[0] >>= 1
                if low == 1 { v[0] ^= 0xe1 }
            }
        }
        x = z
    }

    private static func increment(_ counter: inout [UInt8]) {
        for index in stride(from: 15, through: 12, by: -1) {
            counter[index] &+= 1
            if counter[index] != 0 { break }
        }
    }

    private struct Schedule {
        private let roundKeys: [UInt8]

        init(key: [UInt8]) {
            var expanded = [UInt8](key)
            expanded.reserveCapacity(240)
            var index = 32
            var round = 0
            while index < 240 {
                var word = Array(expanded[index - 4..<index])
                if index % 32 == 0 {
                    word = (1..<4).map { word[$0] } + [word[0]]
                    for i in 0..<4 { word[i] = AES256GCM.sbox[Int(word[i])] }
                    word[0] ^= AES256GCM.rcon[round]
                    round += 1
                } else if index % 32 == 16 {
                    for i in 0..<4 { word[i] = AES256GCM.sbox[Int(word[i])] }
                }
                for i in 0..<4 { expanded.append(expanded[index - 32 + i] ^ word[i]) }
                index += 4
            }
            roundKeys = expanded
        }

        func encrypt(_ block: [UInt8]) -> [UInt8] {
            var state = block
            addRoundKey(&state, offset: 0)
            for round in 1..<14 {
                subBytes(&state)
                shiftRows(&state)
                mixColumns(&state)
                addRoundKey(&state, offset: round * 16)
            }
            subBytes(&state)
            shiftRows(&state)
            addRoundKey(&state, offset: 224)
            return state
        }

        private func addRoundKey(_ state: inout [UInt8], offset: Int) {
            for index in 0..<16 { state[index] ^= roundKeys[offset + index] }
        }

        private func subBytes(_ state: inout [UInt8]) {
            for index in 0..<16 { state[index] = AES256GCM.sbox[Int(state[index])] }
        }

        private func shiftRows(_ state: inout [UInt8]) {
            for row in 1..<4 {
                let values = (0..<4).map { state[row + $0 * 4] }
                for column in 0..<4 { state[row + column * 4] = values[(column + row) % 4] }
            }
        }

        private func mixColumns(_ state: inout [UInt8]) {
            for column in 0..<4 {
                let offset = column * 4
                let a = state[offset], b = state[offset + 1], c = state[offset + 2], d = state[offset + 3]
                let x = a ^ b ^ c ^ d
                state[offset] = a ^ x ^ xtime(a ^ b)
                state[offset + 1] = b ^ x ^ xtime(b ^ c)
                state[offset + 2] = c ^ x ^ xtime(c ^ d)
                state[offset + 3] = d ^ x ^ xtime(d ^ a)
            }
        }

        private func xtime(_ byte: UInt8) -> UInt8 { byte & 0x80 == 0 ? byte << 1 : (byte << 1) ^ 0x1b }
    }

    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40]

    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]
}

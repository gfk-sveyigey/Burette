import Compression
import Foundation

/// 极简 ZIP 读取器：只解出 GitHub Actions 日志压缩包需要的 STORE / DEFLATE 两种条目。
///
/// 之所以自己实现，是因为 iOS 没有内置的解压 API，而日志接口返回的是 zip。
/// 压缩数据是 ZIP 使用的 raw DEFLATE，正好对应 Apple Compression 框架的 COMPRESSION_ZLIB。
enum ZipReader {

    enum ZipError: Error, LocalizedError {
        case invalidArchive
        case unsupportedMethod(Int)
        case inflateFailed

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return "日志压缩包格式无法识别。"
            case .unsupportedMethod(let method): return "日志压缩包使用了不支持的压缩方式（\(method)）。"
            case .inflateFailed: return "解压日志失败。"
            }
        }
    }

    struct Entry {
        let name: String
        let data: Data
    }

    /// 解出压缩包里的所有文件（按中央目录里的顺序）。
    static func entries(from archive: Data) throws -> [Entry] {
        let eocd = try endOfCentralDirectory(in: archive)
        let count = Int(readUInt16(archive, eocd + 10))
        let centralOffset = Int(readUInt32(archive, eocd + 16))
        guard centralOffset < archive.count else { throw ZipError.invalidArchive }

        var result: [Entry] = []
        var cursor = centralOffset

        for _ in 0..<count {
            guard cursor + 46 <= archive.count,
                  readUInt32(archive, cursor) == 0x02014b50 else {
                throw ZipError.invalidArchive
            }
            let method = Int(readUInt16(archive, cursor + 10))
            let compressedSize = Int(readUInt32(archive, cursor + 20))
            let uncompressedSize = Int(readUInt32(archive, cursor + 24))
            let nameLength = Int(readUInt16(archive, cursor + 28))
            let extraLength = Int(readUInt16(archive, cursor + 30))
            let commentLength = Int(readUInt16(archive, cursor + 32))
            let localOffset = Int(readUInt32(archive, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= archive.count else { throw ZipError.invalidArchive }
            let name = String(data: archive.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) ?? ""
            cursor = nameStart + nameLength + extraLength + commentLength

            // 目录条目没有数据。
            if name.hasSuffix("/") { continue }
            // zip64 的占位值，日志包不会用到。
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.invalidArchive
            }

            guard localOffset + 30 <= archive.count,
                  readUInt32(archive, localOffset) == 0x04034b50 else {
                throw ZipError.invalidArchive
            }
            let localNameLength = Int(readUInt16(archive, localOffset + 26))
            let localExtraLength = Int(readUInt16(archive, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= archive.count else { throw ZipError.invalidArchive }
            let payload = archive.subdata(in: dataStart..<(dataStart + compressedSize))

            let data: Data
            switch method {
            case 0:
                data = payload
            case 8:
                data = try inflate(payload, uncompressedSize: uncompressedSize)
            default:
                throw ZipError.unsupportedMethod(method)
            }
            result.append(Entry(name: name, data: data))
        }

        return result
    }

    // MARK: - inflate

    private static func inflate(_ input: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !input.isEmpty else { throw ZipError.inflateFailed }

        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedSize,
                    sourceBase,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ZipError.inflateFailed }
        return output.prefix(written)
    }

    // MARK: - 小端读取

    private static func endOfCentralDirectory(in archive: Data) throws -> Int {
        guard archive.count >= 22 else { throw ZipError.invalidArchive }
        // EOCD 签名后面最多跟 65535 字节注释，从尾部往前找。
        let minOffset = max(0, archive.count - 22 - 65_535)
        var offset = archive.count - 22
        while offset >= minOffset {
            if readUInt32(archive, offset) == 0x06054b50 { return offset }
            offset -= 1
        }
        throw ZipError.invalidArchive
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}

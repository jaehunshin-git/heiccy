import Foundation
import Darwin
import CZlib

enum PNGColorProfile {
    /// Image I/O가 sRGB로 단순화한 경우에도 원본 ICC 고지·색공간을 보존한다.
    static func restore(_ url: URL, profile: Data) throws {
        guard !profile.isEmpty, profile.count <= 16 * 1024 * 1024 else {
            throw NativeConversionError.invalid("ICC 프로파일 크기가 올바르지 않습니다.")
        }
        var capacity = compressBound(uLong(profile.count))
        var compressed = [UInt8](repeating: 0, count: Int(capacity))
        let status = profile.withUnsafeBytes { input in
            compressed.withUnsafeMutableBufferPointer { output in
                compress2(output.baseAddress, &capacity, input.bindMemory(to: Bytef.self).baseAddress,
                          uLong(profile.count), 6)
            }
        }
        guard status == Z_OK else { throw NativeConversionError.io("ICC 프로파일 압축 실패") }
        var payload = Data("ICC Profile".utf8)
        payload.append(contentsOf: [0, 0]); payload.append(contentsOf: compressed.prefix(Int(capacity)))
        let file = try Data(contentsOf: url, options: .alwaysMapped)
        guard file.count >= 33, file.prefix(8) == Data([137,80,78,71,13,10,26,10]) else {
            throw NativeConversionError.invalid("PNG 형식이 올바르지 않습니다.")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".heiccy-icc-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NativeConverter.posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: file.prefix(8))
        var offset = 8, inserted = false
        while offset + 12 <= file.count {
            let size = PNGCompression.number(file, offset)
            guard size <= file.count - offset - 12 else { throw NativeConversionError.invalid("PNG 청크가 불완전합니다.") }
            let type = String(decoding: file[offset + 4..<offset + 8], as: UTF8.self)
            if !inserted, type == "PLTE" || type == "IDAT" {
                try output.write(contentsOf: PNGCompression.chunk("iCCP", payload)); inserted = true
            }
            if !["iCCP", "sRGB", "gAMA", "cHRM"].contains(type) {
                let end = offset + size + 12
                var start = offset
                while start < end {
                    let stop = min(start + 65536, end)
                    try output.write(contentsOf: file.subdata(in: start..<stop)); start = stop
                }
            }
            offset += size + 12
        }
        guard inserted, offset == file.count else { throw NativeConversionError.invalid("PNG 이미지 데이터가 없습니다.") }
        try output.synchronize(); try output.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw NativeConverter.posixError() }
    }
}

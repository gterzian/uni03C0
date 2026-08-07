import Foundation

/// Splits a raw byte stream into JSONL records, splitting on LF (0x0A) only.
///
/// This deliberately does NOT use the stdlib's `Character.isNewline` (which
/// recognizes U+2028/U+2029 and other Unicode line separators) — those are
/// legal inside JSON string payloads and would corrupt framing. Only byte
/// 0x0A terminates a record; a trailing CR (0x0D) is stripped per record to
/// tolerate `\r\n` input, per the RPC framing spec.
public struct JSONLFramer: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Appends bytes and returns any complete records that were terminated.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Data] {
        var records: [Data] = []
        for byte in bytes {
            if byte == 0x0A {
                var record = buffer
                if record.last == 0x0D { record.removeLast() }
                records.append(Data(record))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        return records
    }

    /// Returns any trailing partial record (e.g. final line without a newline at EOF).
    public mutating func drain() -> Data? {
        guard !buffer.isEmpty else { return nil }
        var record = buffer
        if record.last == 0x0D { record.removeLast() }
        buffer.removeAll(keepingCapacity: false)
        return Data(record)
    }
}

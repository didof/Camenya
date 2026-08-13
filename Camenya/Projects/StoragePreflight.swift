import Foundation

enum StoragePreflight {
    static let recordingRequiredBytes: Int64 = 500 * 1_024 * 1_024
    static let outputReserveBytes: Int64 = 250 * 1_024 * 1_024

    static func finalizationRequiredBytes(sourceBytes: Int64) -> Int64 {
        max(outputReserveBytes, sourceBytes)
    }

    static func exportRequiredBytes(sourceBytes: Int64) -> Int64 {
        max(recordingRequiredBytes, sourceBytes + outputReserveBytes)
    }

    static func hasCapacity(requiredBytes: Int64, availableBytes: Int64) -> Bool {
        availableBytes >= requiredBytes
    }
}

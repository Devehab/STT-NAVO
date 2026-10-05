import Darwin
import Foundation

enum ProcessMemory {
    /// Physical memory footprint in bytes: the "Memory" column of Activity Monitor.
    /// It includes GPU (Metal) buffers, which is where MLX keeps the model on Apple Silicon.
    static func footprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static var navo: UInt64? {
        footprint(pid: getpid())
    }

    static func format(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func formatFile(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

import Foundation

/// 字节单位换算与格式化
enum ByteFormatter {
    private static let gb: Double = 1_073_741_824  // 1024^3
    private static let mb: Double = 1_048_576       // 1024^2

    /// 格式化为 GB，保留 2 位小数
    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / gb)
    }

    /// 字节/天，格式化为「X.XX」形式（用于日均消耗展示，单位 GB）
    static func gbPerDay(_ bytesPerDay: Double) -> String {
        String(format: "%.2f", bytesPerDay / gb)
    }

    /// 智能单位（GB / MB / B）
    static func readable(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= gb {
            return String(format: "%.2f GB", value / gb)
        } else if value >= mb {
            return String(format: "%.1f MB", value / mb)
        } else {
            return "\(bytes) B"
        }
    }

    /// 已用 / 总量
    static func usageRatio(used: Int64, total: Int64) -> String {
        "\(gigabytes(used)) / \(gigabytes(total)) GB"
    }
}

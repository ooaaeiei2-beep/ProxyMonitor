import Foundation

/// 每日流量快照，用于推断重置日（检测归零时点）
struct TrafficRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date          // 当天 0 点
    let upload: Int64
    let download: Int64

    var used: Int64 { upload + download }

    init(date: Date, upload: Int64, download: Int64) {
        self.id = UUID()
        self.date = date
        self.upload = upload
        self.download = download
    }
}

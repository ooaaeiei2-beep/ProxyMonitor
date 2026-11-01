import Foundation

/// 流量数据源协议。订阅链接与官网面板各做一个实现，便于扩展。
protocol TrafficProvider {
    func fetchTraffic(for subscription: Subscription) async throws -> TrafficInfo
}

enum TrafficProviderError: LocalizedError {
    case invalidURL
    case noSubscriptionUserinfoHeader
    /// 服务端返回了非 2xx 状态码（保留原值，便于区分 401 与 502 这类性质完全不同的失败）。
    case httpStatus(Int)
    case parseFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "订阅链接无效"
        case .noSubscriptionUserinfoHeader: return "响应未包含 Subscription-Userinfo 头"
        case .httpStatus(let code): return "服务端返回 HTTP \(code)"
        case .parseFailed(let detail): return "解析流量头失败: \(detail)"
        case .networkError(let error): return "网络错误: \(error.localizedDescription)"
        }
    }
}

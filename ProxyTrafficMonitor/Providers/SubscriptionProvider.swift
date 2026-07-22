import Foundation

/// 订阅链接数据源：GET 订阅 URL，解析 Subscription-Userinfo 响应头。
/// 关键点：必须用 GET 请求（非 HEAD），并带 User-Agent，否则机场不返回流量头。
final class SubscriptionProvider: TrafficProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
    }

    func fetchTraffic(for subscription: Subscription) async throws -> TrafficInfo {
        guard let url = URL(string: subscription.url) else {
            throw TrafficProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6   // 单次请求上限 6s（主约束；resource=8 仅兜底，避免先于 request 掐断）
        request.setValue(subscription.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        // 单次请求，失败直接上抛：网络错误 -> URLError；确定性错误（无头/解析失败）-> 对应错误。
        // 不再重试/退避：状态栏程序被动监控，偶发抖动由下个刷新周期兜底。
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrafficProviderError.noSubscriptionUserinfoHeader
        }
        guard let raw = http.value(forHTTPHeaderField: "Subscription-Userinfo"),
              !raw.isEmpty else {
            throw TrafficProviderError.noSubscriptionUserinfoHeader
        }
        return try parse(raw: raw)
    }

    /// 解析 "upload=x; download=y; total=z; expire=t"
    /// 兼容分隔符 ; 或 ,，字段可能缺失（expire 常缺失）
    private func parse(raw: String) throws -> TrafficInfo {
        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: Int64?

        let entries = raw
            .replacingOccurrences(of: ",", with: ";")
            .split(separator: ";")

        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let num = Int64(value) else { continue }
            switch key {
            case "upload": upload = num
            case "download": download = num
            case "total": total = num
            case "expire": expire = num
            default: break
            }
        }

        guard let u = upload, let d = download, let t = total else {
            throw TrafficProviderError.parseFailed(raw)
        }

        return TrafficInfo(
            upload: u,
            download: d,
            total: t,
            expire: (expire ?? 0) > 0 ? expire : nil,
            fetchedAt: Date()
        )
    }
}

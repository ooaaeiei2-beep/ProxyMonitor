import Foundation

/// 订阅链接数据源：GET 订阅 URL，解析 Subscription-Userinfo 响应头。
/// 关键点：必须用 GET 请求（非 HEAD），并带 User-Agent，否则机场不返回流量头。
final class SubscriptionProvider: TrafficProvider {
    private let session: URLSession

    // MARK: - 超时与重试参数

    /// 单次请求的整体超时（秒）。
    ///
    /// 原值 6s。实测云翼网络（阿里云函数计算 `*.fcapp.run`）的 TTFB 地板价即 2.9s、
    /// 尾部采样到 5.5s；而响应体仅 52KB、传输只占 30ms——耗时几乎全部发生在服务端
    /// 返回首字节之前，与本地链路无关（同一时刻 TCP 连接 32ms、TLS 70ms）。
    /// 6s 对这条链路只留 0.4s 余量：日志中 332 轮刷新有 52 次（15.7%）因此超时，
    /// 同期 Cocoduck（Cloudflare，TTFB 稳定 1.39s）只有 8 次。
    /// 本应用是后台静默拉取、用户不可见，放宽超时没有感知成本。
    private static let requestTimeout: TimeInterval = 12
    /// 资源级超时，必须严格大于 requestTimeout，仅作兜底。
    private static let resourceTimeout: TimeInterval = 20
    /// 超时类错误的额外重试次数（不含首次）。
    /// TTFB 抖动是随机的，重试一次大概率命中快实例；实测采样 2.15s / 2.89s / 4.63s / 5.54s 分布很散。
    private static let retryCount = 1
    /// 重试前的等待（纳秒）。
    ///
    /// 分两档：常规链路抖动等 1.5s 即可；唤醒恢复期 / 断网类错误用 4s 长窗口
    /// （实测唤醒到网络可用常在 3~8s，短窗口会在 Wi-Fi 关联完成前就重试）。
    private static let retryDelayNanos: UInt64 = 1_500_000_000
    private static let extendedRetryDelayNanos: UInt64 = 4_000_000_000

    init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.resourceTimeout
        // 刻意保持 false。
        //
        // 曾尝试设为 true 以吸收「系统唤醒后 Wi-Fi 未就绪」导致的 -1009，
        // 但 A/B 实测发现：开启后 URLSession 会忽略 timeoutIntervalForRequest，
        // 请求一直挂到服务器返回为止——本地起一个延迟 20s 的接口，
        // false 时 12s 准时抛 -1001 并按预期重试（两次请求、总 27.6s），
        // true 时却等满 20.03s 才「成功」，超时保护完全失效。
        // 这比偶尔的 -1009 危险得多（服务端挂起会让请求无限滞留），
        // 因此改为在重试层用「断网专用延迟」处理唤醒场景。
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func fetchTraffic(for subscription: Subscription, extendedRetry: Bool) async throws -> TrafficInfo {
        guard let url = URL(string: subscription.url) else {
            throw TrafficProviderError.invalidURL
        }

        var lastError: Error?
        for attempt in 0...Self.retryCount {
            if attempt > 0, let lastError {
                // 用 try 而非 try?：任务被取消时立即上抛，不再发出第二次请求。
                try await Task.sleep(nanoseconds: Self.retryDelay(for: lastError, extendedRetry: extendedRetry))
            }
            do {
                return try await fetchOnce(url: url, subscription: subscription)
            } catch {
                lastError = error
                // 只重试「可能由服务端瞬时抖动造成」的错误。
                // 确定性错误（解析失败、URL 非法、4xx 权限类）重试没有意义。
                guard Self.isTransient(error), attempt < Self.retryCount else { throw error }
                PTMLogger.info("拉取失败，将重试一次（name=\(subscription.name) code=\(Self.shortCode(for: error))）")
            }
        }
        throw lastError ?? TrafficProviderError.noSubscriptionUserinfoHeader
    }

    /// 单次请求：GET，拿响应头即返回。
    ///
    /// 这里保留 `data(for:)` 而非改 `bytes(for:)` + 拿头后取消：订阅响应体实测
    /// 52KB（云翼）/ 116KB（Cocoduck），传输耗时仅 30~470ms，不是瓶颈；
    /// 而 `bytes(for:)` 拿到头就取消会主动断开连接、失去 keep-alive 复用，
    /// 收益不足以抵消新增的出错面。若将来订阅体涨到数百 KB 再考虑切换。
    private func fetchOnce(url: URL, subscription: Subscription) async throws -> TrafficInfo {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(subscription.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrafficProviderError.noSubscriptionUserinfoHeader
        }
        // 非 2xx 一律按状态码归类：4xx（除 429）是确定性错误，5xx / 429 是服务端瞬时故障。
        // 实测云翼网络的函数计算偶发返回异常响应，重试一次即可恢复。
        if !(200...299).contains(http.statusCode) {
            throw TrafficProviderError.httpStatus(http.statusCode)
        }
        guard let raw = http.value(forHTTPHeaderField: "Subscription-Userinfo"),
              !raw.isEmpty else {
            throw TrafficProviderError.noSubscriptionUserinfoHeader
        }
        return try parse(raw: raw)
    }

    /// 是否属于「服务端 / 链路瞬时抖动」类错误——只有这类重试才有意义。
    private static func isTransient(_ error: Error) -> Bool {
        if let providerError = error as? TrafficProviderError {
            switch providerError {
            case .httpStatus(let code):
                // 5xx 与 429 是服务端瞬时故障；其余 4xx 属于配置 / 权限问题，重试无意义。
                return code >= 500 || code == 429
            case .noSubscriptionUserinfoHeader:
                // 实测存在「200 但不带流量头」的偶发响应（一次 10.18s 后返回）。
                // 这种抖动重试一次大概率恢复；若真是 UA 或链接配错，只多花一次等待。
                return true
            case .invalidURL, .parseFailed, .networkError:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        // 链路类瞬时故障纳入重试：
        //  - notConnectedToInternet / cannotConnectToHost：唤醒后 Wi-Fi 尚未关联，首轮常失败；
        //  - secureConnectionFailed(-1200)：网络栈 TLS 未就绪时高发，重试通常即恢复。
        // 实测近 30 天唤醒刷新中 -1200 出现 21 次，原判为确定性错误直接放弃，是「刷新没生效」主因。
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// 按错误类型与场景选择重试等待时长。
    /// 唤醒恢复期（extendedRetry）统一用 4s 长窗口：此时 -1009/-1200/-1004 同源，
    /// 都是网络栈未就绪，1.5s 太短会在 Wi-Fi 关联完成前就重试掉。
    private static func retryDelay(for error: Error, extendedRetry: Bool) -> UInt64 {
        if extendedRetry { return extendedRetryDelayNanos }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return extendedRetryDelayNanos
        }
        return retryDelayNanos
    }

    /// 仅用于日志的短代码，不含 URL（与 TrafficFetcher 的归一化口径一致）。
    private static func shortCode(for error: Error) -> String {
        if let urlError = error as? URLError { return "urlerror_\(urlError.code.rawValue)" }
        if let providerError = error as? TrafficProviderError {
            switch providerError {
            case .invalidURL:                   return "invalid_url"
            case .noSubscriptionUserinfoHeader: return "missing_header"
            case .httpStatus(let code):         return "http_\(code)"
            case .parseFailed:                  return "parse_failed"
            case .networkError:                 return "network"
            }
        }
        return "other"
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

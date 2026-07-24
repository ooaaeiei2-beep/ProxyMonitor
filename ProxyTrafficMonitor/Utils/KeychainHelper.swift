import Foundation
import Security

/// Keychain 封装。用于保存订阅链接（含 token），避免明文写入 UserDefaults。
enum KeychainHelper {
    static let service = "com.xushuda.proxytrafficmonitor"

    /// 后台串行队列：所有 SecItem* 调用都在此队列执行，确保不阻塞主线程（修复 #5 卡 UI 问题）。
    private static let queue = DispatchQueue(label: "com.xushuda.ptm.keychain", qos: .userInitiated)

    /// 写入/覆盖字符串。返回是否成功；失败时仅打日志（不抛错）。
    /// 内部在后台串行队列执行，调用方可 `await` 等待结果（修复 #5）。
    static func save(_ value: String, forKey key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let data = Data(value.utf8)
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
                ]
                // 先删除旧值再写入（upsert）
                SecItemDelete(query as CFDictionary)
                let status = SecItemAdd(query as CFDictionary, nil)
                if status == errSecSuccess {
                    continuation.resume(returning: true)
                } else {
                    PTMLogger.error("Keychain 写入失败 key=\(key) status=\(status)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// 读取字符串，不存在返回 nil
    static func load(_ key: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// 删除。返回是否成功清理（errSecSuccess 或 errSecItemNotFound 视为已清理）。
    static func delete(_ key: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: key
                ]
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess || status == errSecItemNotFound {
                    continuation.resume(returning: true)
                } else {
                    PTMLogger.error("Keychain 删除失败 key=\(key) status=\(status)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

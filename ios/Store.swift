import Foundation
import Security

/// File backed settings and conversations, plus API keys in the Keychain.
/// Mirrors the Kotlin implementation used on Android.
enum Store {
    private static let providers = ["anthropic", "deepseek", "google", "openrouter"]

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func file(_ name: String) -> URL { documents.appendingPathComponent(name) }

    // MARK: - settings

    private static func defaultProviders() -> [String: Any] {
        [
            "anthropic": ["model": "claude-sonnet-5-5", "baseUrl": "https://api.anthropic.com"],
            "deepseek": ["model": "deepseek-flash", "baseUrl": "https://api.deepseek.com"],
            "google": ["model": "gemini-3.8-flash", "baseUrl": "https://generativelanguage.googleapis.com"],
            "openrouter": ["model": "deepseek/deepseek-chat-v3.1:free", "baseUrl": "https://openrouter.ai/api/v1"]
        ]
    }

    static func settings() -> [String: Any] {
        var stored = read(file("settings.json")) as? [String: Any] ?? [:]
        if stored["provider"] == nil { stored["provider"] = "deepseek" }
        if stored["level"] == nil { stored["level"] = "default" }
        if stored["autoApproveReads"] == nil { stored["autoApproveReads"] = true }
        if stored["tokenSaver"] == nil { stored["tokenSaver"] = false }
        if stored["freeMode"] == nil { stored["freeMode"] = false }
        if stored["workspace"] == nil { stored["workspace"] = "Sonekks Chat" }
        if stored["providers"] == nil { stored["providers"] = defaultProviders() }
        return stored
    }

    private static func saveSettings(_ value: [String: Any]) {
        write(value, to: file("settings.json"))
    }

    static func publicSettings() -> [String: Any] {
        let settings = settings()
        let providersJson = settings["providers"] as? [String: Any] ?? [:]
        var out: [String: Any] = [
            "provider": settings["provider"] as? String ?? "deepseek",
            "level": settings["level"] as? String ?? "default",
            "workspace": settings["workspace"] as? String ?? "Sonekks Chat",
            "autoApproveReads": settings["autoApproveReads"] as? Bool ?? true,
            "tokenSaver": settings["tokenSaver"] as? Bool ?? false,
            "freeMode": settings["freeMode"] as? Bool ?? false
        ]

        var outProviders: [String: Any] = [:]
        for id in providers {
            let entry = providersJson[id] as? [String: Any] ?? [:]
            let key = readKey(id)
            outProviders[id] = [
                "model": entry["model"] as? String ?? "",
                "baseUrl": entry["baseUrl"] as? String ?? "",
                "hasKey": key != nil,
                "keyHint": key.map { "..." + String($0.suffix(4)) } ?? NSNull()
            ]
        }
        out["providers"] = outProviders
        return out
    }

    static func savePublicSettings(_ patch: [String: Any]) -> [String: Any] {
        var settings = settings()
        if let value = patch["provider"] as? String, !value.isEmpty { settings["provider"] = value }
        if let value = patch["level"] as? String, !value.isEmpty { settings["level"] = value }
        if let value = patch["workspace"] as? String, !value.isEmpty { settings["workspace"] = value }
        if let value = patch["autoApproveReads"] as? Bool { settings["autoApproveReads"] = value }
        if let value = patch["tokenSaver"] as? Bool { settings["tokenSaver"] = value }
        if let value = patch["freeMode"] as? Bool { settings["freeMode"] = value }

        if let patchProviders = patch["providers"] as? [String: Any] {
            var current = settings["providers"] as? [String: Any] ?? [:]
            for id in providers {
                guard let entry = patchProviders[id] as? [String: Any] else { continue }
                var target = current[id] as? [String: Any] ?? [:]
                if let model = entry["model"] as? String, !model.isEmpty { target["model"] = model }
                if let base = entry["baseUrl"] as? String, !base.isEmpty {
                    target["baseUrl"] = base.hasSuffix("/") ? String(base.dropLast()) : base
                }
                current[id] = target
            }
            settings["providers"] = current
        }

        saveSettings(settings)
        return publicSettings()
    }

    static func setKey(_ provider: String, _ key: String) -> [String: Any] {
        if key.trimmingCharacters(in: .whitespaces).isEmpty {
            deleteKey(provider)
        } else {
            saveKey(provider, key)
        }
        return publicSettings()
    }

    static func activeProvider() -> String { settings()["provider"] as? String ?? "deepseek" }
    static func level() -> String { settings()["level"] as? String ?? "default" }
    static func tokenSaver() -> Bool { settings()["tokenSaver"] as? Bool ?? false }

    static func activeModel(_ provider: String) -> String {
        let providers = settings()["providers"] as? [String: Any] ?? [:]
        return (providers[provider] as? [String: Any])?["model"] as? String ?? ""
    }

    static func activeBaseUrl(_ provider: String) -> String {
        let providers = settings()["providers"] as? [String: Any] ?? [:]
        return (providers[provider] as? [String: Any])?["baseUrl"] as? String ?? ""
    }

    static func sandbox() -> URL {
        let url = documents.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - conversations

    static func conversations() -> [[String: Any]] {
        read(file("conversations.json")) as? [[String: Any]] ?? []
    }

    private static func saveConversations(_ value: [[String: Any]]) {
        write(value, to: file("conversations.json"))
    }

    static func summaries() -> [[String: Any]] {
        conversations()
            .map { conversation in
                [
                    "id": conversation["id"] as? String ?? "",
                    "title": conversation["title"] as? String ?? "New chat",
                    "updatedAt": conversation["updatedAt"] as? Double ?? 0,
                    "provider": conversation["provider"] as? String ?? "deepseek"
                ]
            }
            .sorted { ($0["updatedAt"] as? Double ?? 0) > ($1["updatedAt"] as? Double ?? 0) }
    }

    static func conversation(_ id: String) -> [String: Any]? {
        conversations().first { ($0["id"] as? String) == id }
    }

    static func createConversation() -> [String: Any] {
        let now = Date().timeIntervalSince1970 * 1000
        let conversation: [String: Any] = [
            "id": UUID().uuidString,
            "title": "New chat",
            "createdAt": now,
            "updatedAt": now,
            "provider": activeProvider(),
            "level": level(),
            "messages": []
        ]
        var all = conversations()
        all.append(conversation)
        saveConversations(all)
        return conversation
    }

    static func deleteConversation(_ id: String) {
        saveConversations(conversations().filter { ($0["id"] as? String) != id })
    }

    static func renameConversation(_ id: String, _ title: String) {
        var all = conversations()
        for index in all.indices where (all[index]["id"] as? String) == id {
            all[index]["title"] = title.isEmpty ? "Untitled" : title
        }
        saveConversations(all)
    }

    static func updateConversation(_ conversation: [String: Any]) {
        var updated = conversation
        updated["updatedAt"] = Date().timeIntervalSince1970 * 1000

        if (updated["title"] as? String) == "New chat" {
            let messages = updated["messages"] as? [[String: Any]] ?? []
            if let first = messages.first(where: { ($0["role"] as? String) == "user" }),
               let text = first["text"] as? String, !text.isEmpty {
                updated["title"] = String(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(52))
            }
        }

        var all = conversations()
        var replaced = false
        for index in all.indices where (all[index]["id"] as? String) == (updated["id"] as? String) {
            all[index] = updated
            replaced = true
        }
        if !replaced { all.append(updated) }
        saveConversations(all)
    }

    // MARK: - keychain

    private static let service = "sonekk.chat.keys"

    static func readKey(_ provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveKey(_ provider: String, _ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func deleteKey(_ provider: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - json io

    private static func read(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func write(_ value: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

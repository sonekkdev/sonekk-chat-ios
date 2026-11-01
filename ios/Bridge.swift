import Foundation
import WebKit

/// Receives calls from the web layer and answers through window.__sonekkReply.
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? Int,
              let method = body["method"] as? String else { return }
        let args = body["args"] as? [Any] ?? []

        switch method {
        case "settings":
            reply(id, Store.publicSettings())
        case "saveSettings":
            let patch = args.first as? [String: Any] ?? [:]
            reply(id, Store.savePublicSettings(patch))
        case "setKey":
            let provider = args.first as? String ?? ""
            let key = args.count > 1 ? args[1] as? String ?? "" : ""
            reply(id, Store.setKey(provider, key))
        case "models":
            reply(id, modelList(args.first as? String ?? ""))
        case "testProvider":
            reply(id, ["ok": true, "message": "Saved. Requests are verified when you send a message."])
        case "listConversations":
            reply(id, Store.summaries())
        case "getConversation":
            reply(id, Store.conversation(args.first as? String ?? "") ?? NSNull())
        case "createConversation":
            reply(id, Store.createConversation())
        case "deleteConversation":
            Store.deleteConversation(args.first as? String ?? "")
            reply(id, Store.summaries())
        case "renameConversation":
            Store.renameConversation(args.first as? String ?? "", args.count > 1 ? args[1] as? String ?? "" : "")
            reply(id, Store.summaries())
        case "send":
            let payload = args.first as? [String: Any] ?? [:]
            startAgent(payload)
        case "abort":
            Agent.shared.abort(args.first as? String ?? "")
        case "approve":
            let callId = args.first as? String ?? ""
            let approved = (args.count > 1 ? args[1] as? Bool : false) ?? false
            Agent.shared.approve(callId, approved)
        case "openExternal":
            if let raw = args.first as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
        default:
            reply(id, NSNull())
        }
    }

    private func startAgent(_ payload: [String: Any]) {
        Agent.shared.emit = { [weak self] event in
            self?.event(event)
        }
        Task.detached {
            await Agent.shared.run(
                conversationId: payload["conversationId"] as? String ?? "",
                text: payload["text"] as? String ?? "",
                agentMode: payload["agentMode"] as? Bool ?? true,
                attachments: payload["attachments"] as? [[String: Any]] ?? []
            )
        }
    }

    private func modelList(_ provider: String) -> [String] {
        switch provider {
        case "anthropic": return ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case "deepseek": return ["deepseek-flash", "deepseek-v4-pro"]
        case "google": return ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.7-flash"]
        default: return ["deepseek/deepseek-chat-v3.1:free", "google/gemini-2.0-flash-exp:free"]
        }
    }

    // MARK: - javascript

    private func reply(_ id: Int, _ value: Any) {
        guard let text = jsonText(value) else { return }
        let literal = jsonText(text) ?? "\"null\""
        run("window.__sonekkReply(\(id), \(literal))")
    }

    private func event(_ value: [String: Any]) {
        guard let text = jsonText(value), let literal = jsonText(text) else { return }
        run("window.__sonekkEvent(\(literal))")
    }

    private func run(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func jsonText(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

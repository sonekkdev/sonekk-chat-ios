import Foundation

/// The agent loop, ported from the desktop and Android builds. On iOS there is no
/// shell, so run_command reports that it is unavailable instead of pretending.
final class Agent {
    static let shared = Agent()

    private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    private var aborted: Set<String> = []

    /// Called with a ready event dictionary, the web layer serialises it.
    var emit: (([String: Any]) -> Void)?

    func approve(_ callId: String, _ approved: Bool) {
        guard let continuation = approvals.removeValue(forKey: callId) else { return }
        continuation.resume(returning: approved)
    }

    func abort(_ conversationId: String) {
        aborted.insert(conversationId)
        let pending = approvals
        approvals.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: false) }
    }

    func run(conversationId: String, text: String, agentMode: Bool, attachments: [[String: Any]]) async {
        guard var conversation = Store.conversation(conversationId) else {
            send(["type": "error", "conversationId": conversationId, "message": "Conversation not found."])
            return
        }

        let provider = Store.activeProvider()
        guard let apiKey = Store.readKey(provider), !apiKey.isEmpty else {
            send(["type": "error", "conversationId": conversationId, "message": "No API key saved for \(provider)."])
            send(["type": "done", "conversationId": conversationId, "conversation": conversation])
            return
        }

        var messages = conversation["messages"] as? [[String: Any]] ?? []
        var userMessage: [String: Any] = ["id": UUID().uuidString, "role": "user", "text": text]
        if !attachments.isEmpty { userMessage["attachments"] = attachments }
        messages.append(userMessage)
        conversation["messages"] = messages
        Store.updateConversation(conversation)

        let model = Store.activeModel(provider)
        let level = Store.level()
        let tools = agentMode ? toolDefinitions() : []
        let system = systemPrompt(agentMode)

        do {
            for _ in 0..<12 {
                if aborted.contains(conversationId) { throw CancellationError() }

                let messageId = UUID().uuidString
                send(["type": "start", "conversationId": conversationId, "messageId": messageId])

                var textBuffer = ""
                var calls: [ToolCall] = []
                var usage = Usage()

                let request = StreamRequest(
                    provider: provider,
                    model: model,
                    apiKey: apiKey,
                    baseUrl: Store.activeBaseUrl(provider),
                    level: level,
                    system: system,
                    messages: history(conversation),
                    tools: tools,
                    maxTokens: Store.tokenSaver() ? 2048 : nil
                )

                try await Providers.stream(request) { event in
                    switch event {
                    case let .text(text):
                        textBuffer += text
                        self.send(["type": "delta", "conversationId": conversationId, "messageId": messageId, "text": text])
                    case let .tool(call):
                        calls.append(call)
                    case let .usage(value):
                        usage = value
                    }
                }

                var toolsRecord: [[String: Any]] = calls.map { call in
                    self.send([
                        "type": "tool",
                        "conversationId": conversationId,
                        "messageId": messageId,
                        "call": ["id": call.id, "name": call.name, "input": call.input],
                        "status": "awaiting"
                    ])
                    return ["id": call.id, "name": call.name, "input": call.input]
                }

                var assistant: [String: Any] = [
                    "id": messageId,
                    "role": "assistant",
                    "text": textBuffer,
                    "tools": toolsRecord,
                    "usage": ["inputTokens": usage.inputTokens, "outputTokens": usage.outputTokens],
                    "costUsd": cost(model, usage),
                    "model": model,
                    "provider": provider
                ]
                conversation["messages"] = (conversation["messages"] as? [[String: Any]] ?? []) + [assistant]
                Store.updateConversation(conversation)

                send([
                    "type": "usage",
                    "conversationId": conversationId,
                    "messageId": messageId,
                    "usage": ["inputTokens": usage.inputTokens, "outputTokens": usage.outputTokens],
                    "costUsd": cost(model, usage)
                ])

                if calls.isEmpty { break }

                for call in calls {
                    if aborted.contains(conversationId) { throw CancellationError() }

                    let needsApproval = !["read_file", "list_dir", "search_files"].contains(call.name)
                    var approved = true
                    if needsApproval {
                        send([
                            "type": "approval",
                            "conversationId": conversationId,
                            "call": ["id": call.id, "name": call.name, "input": call.input],
                            "preview": preview(call)
                        ])
                        approved = await withCheckedContinuation { continuation in
                            approvals[call.id] = continuation
                        }
                    }

                    let result = approved
                        ? execute(call.name, call.input)
                        : ("The user denied this action.", true)

                    for index in toolsRecord.indices where (toolsRecord[index]["id"] as? String) == call.id {
                        toolsRecord[index]["output"] = result.0
                        toolsRecord[index]["isError"] = result.1
                    }
                    assistant["tools"] = toolsRecord
                    conversation["messages"] = (conversation["messages"] as? [[String: Any]] ?? []) + []
                    if var all = conversation["messages"] as? [[String: Any]],
                       let last = all.indices.last {
                        all[last] = assistant
                        conversation["messages"] = all
                    }
                    Store.updateConversation(conversation)

                    send([
                        "type": "tool-output",
                        "conversationId": conversationId,
                        "messageId": messageId,
                        "callId": call.id,
                        "output": result.0,
                        "isError": result.1,
                        "status": !approved ? "denied" : (result.1 ? "error" : "done")
                    ])
                }
            }

            send(["type": "done", "conversationId": conversationId, "conversation": conversation])
        } catch is CancellationError {
            send(["type": "aborted", "conversationId": conversationId])
            send(["type": "done", "conversationId": conversationId, "conversation": conversation])
        } catch {
            send(["type": "error", "conversationId": conversationId, "message": error.localizedDescription])
            send(["type": "done", "conversationId": conversationId, "conversation": conversation])
        }

        aborted.remove(conversationId)
    }

    private func history(_ conversation: [String: Any]) -> [[String: Any]] {
        let messages = conversation["messages"] as? [[String: Any]] ?? []
        let limit = Store.tokenSaver() ? 8 : 40
        return Array(messages.suffix(limit))
    }

    private func systemPrompt(_ agentMode: Bool) -> String {
        let base = "You are Sonekks Chat, a local assistant running on iOS.\nLevel: \(Store.level())\n"
        if !agentMode { return base + "\nYou are in CHAT MODE." }
        return base + "\nYou are in AGENT MODE. Files live in the app sandbox. There is no shell on iOS."
    }

    private func cost(_ model: String, _ usage: Usage) -> Double {
        if model.contains(":free") { return 0 }
        let prices: [(String, Double, Double)] = [
            ("claude-opus-5", 4, 20), ("claude-sonnet-5", 2, 10), ("claude-haiku-5", 0.1, 0.5),
            ("deepseek-v4-pro", 1.32, 3.96), ("deepseek-flash", 0.3, 1.2),
            ("gemini-4-argon", 2, 10), ("gemini-3.8-flash", 0.75, 3.75), ("gemini-2.5-flash", 0.3, 2.5)
        ]
        guard let price = prices.first(where: { model.hasPrefix($0.0) }) else { return 0 }
        return Double(usage.inputTokens) / 1_000_000 * price.1 + Double(usage.outputTokens) / 1_000_000 * price.2
    }

    private func preview(_ call: ToolCall) -> String {
        switch call.name {
        case "run_command": return call.input["command"] as? String ?? ""
        case "write_file": return "\(call.input["path"] as? String ?? "") — \(((call.input["content"] as? String) ?? "").count) chars"
        default: return call.input["path"] as? String ?? "."
        }
    }

    private func send(_ event: [String: Any]) {
        emit?(event)
    }

    // MARK: - tools

    private func toolDefinitions() -> [[String: Any]] {
        func schema(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let path: [String: Any] = ["type": "string", "description": "Path relative to the workspace."]

        return [
            ["name": "read_file", "description": "Read a text file from the workspace.", "parameters": schema(["path": path], ["path"])],
            ["name": "write_file", "description": "Create or overwrite a text file.", "parameters": schema(["path": path, "content": ["type": "string"]], ["path", "content"])],
            ["name": "edit_file", "description": "Replace an exact string in a file.", "parameters": schema(["path": path, "old_string": ["type": "string"], "new_string": ["type": "string"]], ["path", "old_string", "new_string"])],
            ["name": "list_dir", "description": "List a directory.", "parameters": schema(["path": path], [])],
            ["name": "search_files", "description": "Search file contents with a regular expression.", "parameters": schema(["pattern": ["type": "string"], "path": path], ["pattern"])],
            ["name": "run_command", "description": "Not available on iOS. Returns an error.", "parameters": schema(["command": ["type": "string"]], ["command"])]
        ]
    }

    private func execute(_ name: String, _ input: [String: Any]) -> (String, Bool) {
        do {
            switch name {
            case "run_command":
                return ("run_command is not available on iOS. There is no shell in the app sandbox.", true)
            case "read_file":
                let url = try resolve(input["path"] as? String ?? "")
                return (try String(contentsOf: url, encoding: .utf8), false)
            case "write_file":
                let url = try resolve(input["path"] as? String ?? "")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (input["content"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8)
                return ("wrote \(input["path"] as? String ?? "")", false)
            case "edit_file":
                let url = try resolve(input["path"] as? String ?? "")
                let old = input["old_string"] as? String ?? ""
                let new = input["new_string"] as? String ?? ""
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.contains(old) else { return ("old_string not found", true) }
                try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
                return ("patched \(input["path"] as? String ?? "")", false)
            case "list_dir":
                let url = try resolve(input["path"] as? String ?? ".")
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return (entries.sorted().joined(separator: "\n"), false)
            case "search_files":
                let pattern = input["pattern"] as? String ?? ""
                let regex = try NSRegularExpression(pattern: pattern)
                let root = try resolve(input["path"] as? String ?? ".")
                var matches: [String] = []
                if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let file as URL in enumerator {
                        if matches.count > 80 { break }
                        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                            let range = NSRange(line.startIndex..., in: line)
                            if regex.firstMatch(in: line, range: range) != nil {
                                matches.append("\(file.lastPathComponent):\(index + 1): \(line.prefix(160))")
                            }
                        }
                    }
                }
                return (matches.isEmpty ? "no matches" : matches.joined(separator: "\n"), false)
            default:
                return ("unknown tool: \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func resolve(_ relative: String) throws -> URL {
        let root = Store.sandbox().standardizedFileURL
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw NSError(domain: "sonekk", code: 1, userInfo: [NSLocalizedDescriptionKey: "path escapes the workspace"])
        }
        return target
    }
}

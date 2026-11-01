import Foundation

struct ToolCall {
    let id: String
    let name: String
    let input: [String: Any]
}

struct Usage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
}

enum StreamEvent {
    case text(String)
    case tool(ToolCall)
    case usage(Usage)
}

struct StreamRequest {
    let provider: String
    let model: String
    let apiKey: String
    let baseUrl: String
    let level: String
    let system: String
    let messages: [[String: Any]]
    let tools: [[String: Any]]
    let maxTokens: Int?
}

enum ProviderError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        }
    }
}

/// Streaming clients for the same four providers the desktop and Android builds use.
enum Providers {
    static func stream(_ request: StreamRequest, onEvent: @escaping (StreamEvent) -> Void) async throws {
        switch request.provider {
        case "anthropic": try await streamAnthropic(request, onEvent)
        case "google": try await streamGoogle(request, onEvent)
        default: try await streamOpenAi(request, onEvent)
        }
    }

    // MARK: - helpers

    private static func textAttachments(_ message: [String: Any]) -> String {
        var text = message["text"] as? String ?? ""
        for attachment in message["attachments"] as? [[String: Any]] ?? [] where (attachment["kind"] as? String) == "text" {
            text += "\n\n--- Attached file: \(attachment["name"] as? String ?? "file") ---\n```\n\(attachment["data"] as? String ?? "")\n```"
        }
        return text
    }

    private static func images(_ message: [String: Any]) -> [[String: Any]] {
        (message["attachments"] as? [[String: Any]] ?? []).filter { ($0["kind"] as? String) == "image" }
    }

    private static func plan(_ provider: String, _ level: String) -> (Int, String) {
        switch provider {
        case "anthropic":
            switch level {
            case "fast": return (4096, "low")
            case "default": return (8192, "medium")
            case "high": return (16000, "high")
            default: return (32000, "high")
            }
        case "google":
            switch level {
            case "fast": return (4096, "low")
            case "default": return (8192, "medium")
            case "high": return (16384, "high")
            default: return (32768, "high")
            }
        default:
            switch level {
            case "fast": return (2048, "")
            case "default": return (4096, "")
            case "high": return (8192, "")
            default: return (16384, "")
            }
        }
    }

    // MARK: - anthropic

    private static func streamAnthropic(_ request: StreamRequest, _ onEvent: @escaping (StreamEvent) -> Void) async throws {
        let (maxTokens, effort) = plan("anthropic", request.level)
        var messages: [[String: Any]] = []

        for message in request.messages {
            if (message["role"] as? String) == "user" {
                var blocks: [[String: Any]] = []
                let text = textAttachments(message)
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for image in images(message) {
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": image["mime"] as? String ?? "image/png",
                            "data": image["data"] as? String ?? ""
                        ]
                    ])
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "(empty)"]) }
                messages.append(["role": "user", "content": blocks])
            } else {
                var blocks: [[String: Any]] = []
                let text = message["text"] as? String ?? ""
                if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                let tools = message["tools"] as? [[String: Any]] ?? []
                for tool in tools {
                    blocks.append([
                        "type": "tool_use",
                        "id": tool["id"] as? String ?? "",
                        "name": tool["name"] as? String ?? "",
                        "input": tool["input"] as? [String: Any] ?? [:]
                    ])
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "(no content)"]) }
                messages.append(["role": "assistant", "content": blocks])

                if !tools.isEmpty {
                    messages.append([
                        "role": "user",
                        "content": tools.map { tool in
                            [
                                "type": "tool_result",
                                "tool_use_id": tool["id"] as? String ?? "",
                                "content": tool["output"] as? String ?? "(no output)",
                                "is_error": tool["isError"] as? Bool ?? false
                            ]
                        }
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens ?? maxTokens,
            "system": request.system,
            "messages": messages,
            "stream": true,
            "output_config": ["effort": effort]
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool["name"] as? String ?? "",
                    "description": tool["description"] as? String ?? "",
                    "input_schema": tool["parameters"] as? [String: Any] ?? [:]
                ]
            }
        }

        var urlRequest = URLRequest(url: URL(string: "\(request.baseUrl)/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var blocks: [Int: (String, String, String)] = [:]
        var usage = Usage()

        try await forEachEvent(urlRequest) { event in
            switch event["type"] as? String {
            case "message_start":
                if let u = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    usage.inputTokens = u["input_tokens"] as? Int ?? 0
                    usage.outputTokens = u["output_tokens"] as? Int ?? 0
                    onEvent(.usage(usage))
                }
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], (block["type"] as? String) == "tool_use" {
                    blocks[event["index"] as? Int ?? 0] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                }
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty { onEvent(.text(text)) }
                case "input_json_delta":
                    let index = event["index"] as? Int ?? 0
                    if var current = blocks[index] {
                        current.2 += delta["partial_json"] as? String ?? ""
                        blocks[index] = current
                    }
                default: break
                }
            case "content_block_stop":
                let index = event["index"] as? Int ?? 0
                if let block = blocks.removeValue(forKey: index) {
                    let input = (try? JSONSerialization.jsonObject(with: Data(block.2.utf8))) as? [String: Any] ?? [:]
                    onEvent(.tool(ToolCall(id: block.0, name: block.1, input: input)))
                }
            case "message_delta":
                if let u = event["usage"] as? [String: Any] {
                    usage.outputTokens = max(usage.outputTokens, u["output_tokens"] as? Int ?? 0)
                    onEvent(.usage(usage))
                }
            default: break
            }
        }
    }

    // MARK: - openai compatible

    private static func streamOpenAi(_ request: StreamRequest, _ onEvent: @escaping (StreamEvent) -> Void) async throws {
        let (maxTokens, _) = plan("deepseek", request.level)
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]

        for message in request.messages {
            if (message["role"] as? String) == "user" {
                let text = textAttachments(message)
                let images = images(message)
                if images.isEmpty {
                    messages.append(["role": "user", "content": text.isEmpty ? "(empty)" : text])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "(image attached)" : text]]
                    for image in images {
                        let mime = image["mime"] as? String ?? "image/png"
                        let data = image["data"] as? String ?? ""
                        parts.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data)"]])
                    }
                    messages.append(["role": "user", "content": parts])
                }
            } else {
                var entry: [String: Any] = ["role": "assistant"]
                let text = message["text"] as? String ?? ""
                entry["content"] = text.isEmpty ? NSNull() : text
                let tools = message["tools"] as? [[String: Any]] ?? []
                if !tools.isEmpty {
                    entry["tool_calls"] = tools.map { tool in
                        [
                            "id": tool["id"] as? String ?? "",
                            "type": "function",
                            "function": [
                                "name": tool["name"] as? String ?? "",
                                "arguments": jsonString(tool["input"] as? [String: Any] ?? [:])
                            ]
                        ]
                    }
                }
                messages.append(entry)
                for tool in tools {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": tool["id"] as? String ?? "",
                        "content": tool["output"] as? String ?? "(no output)"
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": request.maxTokens ?? maxTokens
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool["name"] as? String ?? "",
                        "description": tool["description"] as? String ?? "",
                        "parameters": tool["parameters"] as? [String: Any] ?? [:]
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }

        var urlRequest = URLRequest(url: URL(string: "\(request.baseUrl)/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var calls: [Int: (String, String, String)] = [:]
        var usage = Usage()

        try await forEachEvent(urlRequest) { event in
            if let u = event["usage"] as? [String: Any] {
                usage.inputTokens = u["prompt_tokens"] as? Int ?? usage.inputTokens
                usage.outputTokens = u["completion_tokens"] as? Int ?? usage.outputTokens
                onEvent(.usage(usage))
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { return }

            if let text = delta["content"] as? String, !text.isEmpty { onEvent(.text(text)) }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for (offset, part) in toolCalls.enumerated() {
                    let index = part["index"] as? Int ?? offset
                    var current = calls[index] ?? ("", "", "")
                    current.0 = part["id"] as? String ?? current.0
                    if let function = part["function"] as? [String: Any] {
                        current.1 += function["name"] as? String ?? ""
                        current.2 += function["arguments"] as? String ?? ""
                    }
                    calls[index] = current
                }
            }
        }

        for (_, call) in calls.sorted(by: { $0.key < $1.key }) {
            let input = (try? JSONSerialization.jsonObject(with: Data(call.2.utf8))) as? [String: Any] ?? [:]
            onEvent(.tool(ToolCall(id: call.0.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : call.0, name: call.1, input: input)))
        }
    }

    // MARK: - google

    private static func streamGoogle(_ request: StreamRequest, _ onEvent: @escaping (StreamEvent) -> Void) async throws {
        let (maxTokens, thinking) = plan("google", request.level)
        var contents: [[String: Any]] = []

        for message in request.messages {
            if (message["role"] as? String) == "user" {
                var parts: [[String: Any]] = []
                let text = textAttachments(message)
                if !text.isEmpty { parts.append(["text": text]) }
                for image in images(message) {
                    parts.append(["inlineData": [
                        "mimeType": image["mime"] as? String ?? "image/png",
                        "data": image["data"] as? String ?? ""
                    ]])
                }
                if parts.isEmpty { parts.append(["text": "(empty)"]) }
                contents.append(["role": "user", "parts": parts])
            } else {
                var parts: [[String: Any]] = []
                let text = message["text"] as? String ?? ""
                if !text.isEmpty { parts.append(["text": text]) }
                let tools = message["tools"] as? [[String: Any]] ?? []
                for tool in tools {
                    parts.append(["functionCall": [
                        "name": tool["name"] as? String ?? "",
                        "args": tool["input"] as? [String: Any] ?? [:]
                    ]])
                }
                if parts.isEmpty { parts.append(["text": "(no content)"]) }
                contents.append(["role": "model", "parts": parts])

                if !tools.isEmpty {
                    contents.append([
                        "role": "user",
                        "parts": tools.map { tool in
                            [
                                "functionResponse": [
                                    "name": tool["name"] as? String ?? "",
                                    "response": ["result": tool["output"] as? String ?? ""]
                                ]
                            ]
                        }
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": request.system]]],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": request.maxTokens ?? maxTokens,
                "thinkingConfig": ["thinkingLevel": thinking]
            ]
        ]
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool["name"] as? String ?? "",
                        "description": tool["description"] as? String ?? "",
                        "parameters": tool["parameters"] as? [String: Any] ?? [:]
                    ]
                }
            ]]
        }

        let encodedModel = request.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? request.model
        let url = "\(request.baseUrl)/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse&key=\(request.apiKey)"
        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var usage = Usage()
        var index = 0

        try await forEachEvent(urlRequest) { event in
            if let u = event["usageMetadata"] as? [String: Any] {
                usage.inputTokens = u["promptTokenCount"] as? Int ?? usage.inputTokens
                usage.outputTokens = u["candidatesTokenCount"] as? Int ?? usage.outputTokens
                onEvent(.usage(usage))
            }
            guard let candidate = (event["candidates"] as? [[String: Any]])?.first,
                  let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return }

            for part in parts {
                if let call = part["functionCall"] as? [String: Any] {
                    index += 1
                    onEvent(.tool(ToolCall(
                        id: "g_\(index)_\(UUID().uuidString.prefix(6))",
                        name: call["name"] as? String ?? "",
                        input: call["args"] as? [String: Any] ?? [:]
                    )))
                } else if let text = part["text"] as? String, !text.isEmpty, !(part["thought"] as? Bool ?? false) {
                    onEvent(.text(text))
                }
            }
        }
    }

    // MARK: - sse

    private static func forEachEvent(_ request: URLRequest, _ handler: @escaping ([String: Any]) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.http(0, "no response") }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines.prefix(20) { body += line }
            throw ProviderError.http(http.statusCode, body)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handler(object)
        }
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

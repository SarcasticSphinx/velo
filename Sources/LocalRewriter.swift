import Foundation

/// Opt-in localhost request; Ollama is not launched by this application.
enum LocalRewriter {
    private struct Request: Encodable {
        let model = "gemma3:1b"
        let system: String
        let prompt: String
        let stream = false
        let keep_alive = 0
        let options: Options
        struct Options: Encodable {
            let temperature = 0.0
            let num_predict: Int
        }
    }
    private struct Response: Decodable { let response: String }

    static func rewrite(_ text: String, vocabulary: [String], context: String,
                        completion: @escaping (String) -> Void) {
        let payload = Request(system: RewritePrompt.system(context: context, vocabulary: vocabulary), prompt: text,
                              options: .init(num_predict: RewritePrompt.maxTokens(for: text)))
        guard let url = URL(string: "http://127.0.0.1:11434/api/generate"),
              let body = try? JSONEncoder().encode(payload) else {
            completion(text)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: String
            if error == nil,
               let response = response as? HTTPURLResponse, response.statusCode == 200,
               let data, let decoded = try? JSONDecoder().decode(Response.self, from: data),
               !decoded.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                result = text // Never lose the transcript when Ollama isn't running.
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

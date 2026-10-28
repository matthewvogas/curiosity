import Foundation

/// El Hub de Hugging Face: buscar datasets de LeRobot. Devuelve los datos crudos de la API.
enum HubQueries {
    /// Datasets de LeRobot que coinciden con `query`, los más descargados primero.
    static func searchDatasets(_ query: String, token: String?) async throws -> [HubDataset] {
        var c = URLComponents(string: "https://huggingface.co/api/datasets")!
        c.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "LeRobot"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "40"),
        ]
        var request = URLRequest(url: c.url!)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Curiosity", code: 4, userInfo: [NSLocalizedDescriptionKey: "The Hugging Face Hub didn't respond."])
        }
        return list.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return HubDataset(id: id, downloads: (d["downloads"] as? NSNumber)?.intValue ?? 0, likes: (d["likes"] as? NSNumber)?.intValue ?? 0)
        }
    }
}

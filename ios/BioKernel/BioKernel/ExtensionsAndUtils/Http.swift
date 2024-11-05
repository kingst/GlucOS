//
//  Http.swift
//  BioKernel
//
//  Created by Sam King on 11/22/23.
//

import Foundation

protocol Http {
    func post<ResponseType>(url: String, data: Encodable, headers: [String: String]) async -> ResponseType? where ResponseType: Decodable
    func get<ResponseType>(url: String, headers: [String : String]) async -> ResponseType? where ResponseType : Decodable
}

extension Http {
    func post<ResponseType>(url: String, data: Encodable) async -> ResponseType? where ResponseType: Decodable {
        return await post(url: url, data: data, headers: [:])
    }
    
    func get<ResponseType>(url: String) async -> ResponseType? where ResponseType : Decodable {
        return await get(url: url, headers: [:])
    }
}

struct JsonHttp: Http {
    static let shared = JsonHttp()
    
    func post<ResponseType>(url: String, data: Encodable, headers: [String : String]) async -> ResponseType? where ResponseType : Decodable {
        
        guard let url = URL(string: url) else { return nil }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let jsonData = try? encoder.encode(data) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(ResponseType.self, from: data)
        } catch {
            print("error decoding: \(String(describing: error))")
            return nil
        }
    }
    
    private func getOrHead<ResponseType>(method: String, url: String, headers: [String : String]) async -> ResponseType? where ResponseType : Decodable {
        guard let url = URL(string: url) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ResponseType.self, from: data)
    }
    
    func get<ResponseType>(url: String, headers: [String : String]) async -> ResponseType? where ResponseType : Decodable {
        return await getOrHead(method: "GET", url: url, headers: headers)
    }
}

//
//  UserDefaults+Json.swift
//  BioKernel
//
//  Created by Sam King on 12/13/23.
//

import Foundation

extension UserDefaults {
    func json<ResponseType>(forKey: String) -> ResponseType? where ResponseType : Decodable {
        guard let data = UserDefaults.standard.data(forKey: forKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ResponseType.self, from: data)
    }
    
    // this fails silently, which might be a problem
    func set(json: Encodable, forKey: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let jsonData = try? encoder.encode(json) else { return }
        UserDefaults.standard.set(jsonData, forKey: forKey)
        UserDefaults.standard.synchronize()
    }
}

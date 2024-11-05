//
//  StoredJsonObject.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import Foundation

public protocol StoredObject {
    func read<T: Decodable>() throws -> T?
    func write<T: Encodable>(_ object: T) throws
    static func create(fileName: String) -> StoredObject
}

struct StoredJsonObject: StoredObject {
    let storageURL: URL
    let fileName: String
    
    static func create(fileName: String) -> StoredObject {
        return StoredJsonObject(fileName: fileName)
    }
    
    enum StoredJsonObjectError: Error {
        case fileSystemWriteError
        case fileSystemReadError
        case encodingError
        case decodingError
    }
    
    init(fileName: String) {
        self.fileName = fileName
        let documents: URL

        guard let localDocuments = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            preconditionFailure("Could not get a documents directory URL.")
        }
        documents = localDocuments

        storageURL = documents.appendingPathComponent(fileName)
        print("Setting storage file at \(storageURL)")
    }
    
    func read<T: Decodable>() throws -> T? {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let decodedObject = try decoder.decode(T.self, from: data)
            return decodedObject
        } catch _ as DecodingError {
            // before we throw this error try with ISO8601 parsing instead
            do {
                print("Falling back to iso8601 timestamp parsing for \(storageURL)")
                let data = try Data(contentsOf: storageURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decodedObject = try decoder.decode(T.self, from: data)
                print("successfully parsed iso8601 timestamps")
                return decodedObject
            } catch {
                throw StoredJsonObjectError.decodingError
            }
        } catch let error as NSError {
            switch error.code {
            case NSFileReadNoSuchFileError:
                print("No file at \(storageURL), returning nil")
                return nil
            case NSFileReadInapplicableStringEncodingError, NSFileReadCorruptFileError:
                throw StoredJsonObjectError.decodingError
            default:
                throw StoredJsonObjectError.fileSystemReadError
            }
        } catch {
            throw StoredJsonObjectError.fileSystemReadError
        }
    }
    
    func write<T: Encodable>(_ object: T) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if debugEnabled {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            }
            let data = try encoder.encode(object)
            try data.write(to: storageURL, options: .atomic)
        } catch _ as EncodingError {
            throw StoredJsonObjectError.encodingError
        } catch {
            throw StoredJsonObjectError.fileSystemWriteError
        }
    }
}

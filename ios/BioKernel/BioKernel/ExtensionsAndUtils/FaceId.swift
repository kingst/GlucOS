//
//  FaceID.swift
//  BioKernel
//
//  Created by Sam King on 11/27/23.
//

import LocalAuthentication

enum FaceIdError: Error {
    case cantEvaluatePolicy
    case authenticationFailed
}

struct FaceId {
    
    @MainActor
    static func authenticate() async -> FaceIdError? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            print(error?.localizedDescription ?? "Can't evaluate policy")
            return .cantEvaluatePolicy
        }
        
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Save settings")
            return nil
        } catch let error {
            print(error.localizedDescription)
            return .authenticationFailed
        }
    }
}

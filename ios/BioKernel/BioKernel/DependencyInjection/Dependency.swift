//
//  Dependency.swift
//  Type Zero
//
//  Created by Sam King on 1/24/23.
//  Copyright © 2023 Sam King. All rights reserved.
//
//  Inspired by this: https://www.youtube.com/watch?v=dA9rGQRwHGs
//

import Foundation

struct Dependency {
    private static var constructors: [String: Any] = [:]
    private static var mockConstructors: [String: Any] = [:]
    static var useMockConstructors = false
    
    // we make sure that all accesses of the dictionaries are done in a dispatch queue
    // to ensure thread safety. All of the functions that mutate a dictionary are called
    // async, so will execute in order. The `instance` method returns a value, so we use
    // sync as a form of barrier synchronization to ensure that all mutations complete before
    // this function returns a value, maintaining correct operation order.
    private static let queue = DispatchQueue(label: "DI synchronization queue")
    
    static func bind<T>(constructor: @escaping () -> T) -> () -> T {
        queue.async {
            let key = String(describing: T.self)
            constructors[key] = constructor
        }
    
        return instance
    }
    
    static func mock<T>(constructor: @escaping () -> T) {
        queue.async {
            let key = String(describing: T.self)
            mockConstructors[key] = constructor
        }
    }

    static func resetMocks() {
        queue.async {
            mockConstructors = [:]
        }
    }
    
    private static func instance<T>() -> T {
        let key = String(describing: T.self)
        var constructor: (() -> T)? = nil
        
        // make sure all previous mutations are done before returning
        queue.sync {
            if useMockConstructors {
                constructor = mockConstructors[key] as? () -> T
            } else {
                constructor = constructors[key] as? () -> T
            }
        }
        
        // forced unwrapping is safe here, it won't crash unless useMockConstructors is true
        // in which case we're testing and want it to crash because it will tell use that
        // our code is using a object that we didn't mock
        return constructor!()
    }
}

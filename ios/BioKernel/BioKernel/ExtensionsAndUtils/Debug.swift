//
//  Debug.swift
//  Loop
//
//  Created by Michael Pangburn on 3/5/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//
import Foundation

var debugEnabled: Bool {
    #if DEBUG || IOS_SIMULATOR || targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}

var isRunningTests: Bool {
    return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

func assertDebugOnly(file: StaticString = #file, line: UInt = #line) {
    guard debugEnabled else {
        fatalError("\(file):\(line) should never be invoked in release builds", file: file, line: line)
    }
}

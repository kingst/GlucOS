//
//  CheckCgmConnectionIntentTests.swift
//  BioKernelTests
//
//  `CheckCgmConnectionIntent` gets `AppComposition` from the
//  `AppDependencyManager` registration in `BioKernelApp.init`. Under tests
//  that registration is nil, so `perform()` must throw. If the registration
//  went missing, reading the `@Dependency` would trap and this test would
//  crash rather than pass.
//

import Testing
@testable import BioKernel

@MainActor
struct CheckCgmConnectionIntentTests {

    @Test func performThrowsWithoutComposition() async {
        await #expect(throws: CheckCgmConnectionError.self) {
            _ = try await CheckCgmConnectionIntent().perform()
        }
    }
}

//
//  DateTime.swift
//  BioKernelTests
//
//  Created by Sam King on 1/23/24.
//

import Foundation

@testable import BioKernel

extension Date {
    static func f(_ input: String) -> Date {
        return ClockDateTime().parse(input, formatter: .humanReadable)!
    }
}

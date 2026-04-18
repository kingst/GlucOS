//
//  DosingDecisionTestHelpers.swift
//  BioKernelTests
//
//  Created by Sam King on 4/18/26.
//

import Foundation
@testable import BioKernel

extension DosingDecision {
    var tempBasal: Double {
        if case .tempBasal(let units) = self { return units }
        return 0
    }
    var microBolus: Double {
        if case .microBolus(let units) = self { return units }
        return 0
    }
}

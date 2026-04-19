//
//  DosingDecisionTestHelpers.swift
//  BioKernelTests
//
//  Created by Sam King on 4/18/26.
//

import Foundation
@testable import BioKernel

extension DosingDecision {
    var tempBasalUnitsPerHour: Double {
        if case .tempBasal(let unitsPerHour) = self { return unitsPerHour }
        return 0
    }
    var microBolusUnits: Double {
        if case .microBolus(let units) = self { return units }
        return 0
    }
}

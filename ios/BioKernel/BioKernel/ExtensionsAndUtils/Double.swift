//
//  Clamp.swift
//  BioKernel
//
//  Created by Sam King on 1/20/24.
//

import Foundation

extension Double {
    func clamp(low: Double, high: Double) -> Double {
        if self < low {
            return low
        } else if self > high {
            return high
        } else {
            return self
        }
    }
    
    func roughlyEqual(to: Double, error: Double = 0.01) -> Bool {
        return self >= (to - error) && self <= (to + error)
    }
}

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

extension Double {
    /// Snaps to the nearest multiple of `increment`, half away from zero.
    ///
    /// Written for dose arithmetic, where the increment is a pump's smallest
    /// delivery unit and an unrounded value is not a dose the pump can give. A
    /// non-positive increment has no nearest multiple, so it returns `self`
    /// rather than dividing by zero.
    func rounded(toNearest increment: Double) -> Double {
        guard increment > 0 else { return self }
        let steps = (self / increment).rounded()
        // `steps * increment` alone reintroduces binary dust for the decimal
        // increments a pump actually uses — 66 * 0.05 is 3.3000000000000003,
        // not 3.3. These values are stored, compared and shown as doses, so the
        // product is snapped to a precision far finer than any increment while
        // still coarser than the error.
        return (steps * increment * 1e6).rounded() / 1e6
    }
}

//
//  DateExtensions.swift
//  BioKernel
//
//  Created by Sam King on 11/3/23.
//

import Foundation

extension Double {
    func minutesToSeconds() -> Double { return self * 60.0 }
    func hoursToSeconds() -> Double { return (self * 60.0).minutesToSeconds() }
    func daysToSeconds() -> Double { return (self * 24).hoursToSeconds() }
    func secondsToMinutes() -> Double { return self / 60.0 }
}

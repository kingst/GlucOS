//
//  AddedGlucoseDataFrame.swift
//  BioKernel
//
//  Created by Sam King on 1/21/24.
//

import Foundation
import LoopKit

public struct AddedGlucoseDataRow: Codable {
    let eventTime: Date
    let glucose: Double
    let insulinDelivered: Double
    let insulinOnBoard: Double
}

extension Array<AddedGlucoseDataRow> {
    // Calculate added glucose starting at the most recent (i.e. the last)
    // row and including `numberOfRows` rows. This function will normalize
    // added glucose to be per hour but bases the calculation on the
    // numberOfRows time span.
    //
    // Note: if you set numberOfRows to 2 it will span 5 minutes, 3 spans
    // 10 minutes and so on.
    func addedGlucosePerHour(numberOfRows: Int, insulinSensitivity: Double) -> Double? {
        guard self.count >= numberOfRows, numberOfRows > 1 else { return nil }
        let dataFrame = self.dropFirst(self.count - numberOfRows)
        
        let addedGlucosePerStep = zip(dataFrame, dataFrame.dropFirst()).map { (prev, curr) -> Double in
            let deltaGlucose = curr.glucose - prev.glucose
            let insulinActive = prev.insulinOnBoard - curr.insulinOnBoard + curr.insulinDelivered
            return deltaGlucose + insulinActive * insulinSensitivity
        }
        let addedGlucose = addedGlucosePerStep.reduce(0, +)
        
        return addedGlucose * 12 / Double(numberOfRows - 1) // convert to per hour
    }
    
    func addedGlucosePerHour30m(insulinSensitivity: Double) -> Double? {
        return addedGlucosePerHour(numberOfRows: 7, insulinSensitivity: insulinSensitivity)
    }
}

public struct AddedGlucoseDataFrame {
    static let timeStep = 5.minutesToSeconds()
    
    // this function is extremely inefficient but as long as n is small we should be fine
    static func glucoseIterpolation(samples: [NewGlucoseSample], eventTime: Date) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if eventTime < first.date { return first.quantity.doubleValue(for: .milligramsPerDeciliter) }
        if eventTime >= last.date { return last.quantity.doubleValue(for: .milligramsPerDeciliter) }
        
        for (curr, next) in zip(samples, samples.dropFirst()) {
            if eventTime >= curr.date && eventTime < next.date {
                let delta = next.quantity.doubleValue(for: .milligramsPerDeciliter) - curr.quantity.doubleValue(for: .milligramsPerDeciliter)
                let duration = next.date.timeIntervalSince(curr.date)
                guard duration > .ulpOfOne else {
                    return nil
                }

                let increment = eventTime.timeIntervalSince(curr.date)
                return curr.quantity.doubleValue(for: .milligramsPerDeciliter) + delta * increment / duration
            }
        }
        
        return nil
    }
    
    static func createDataFrame(at: Date, numberOfRows: Int, minNumberOfGlucoseSamples: Int) async -> [AddedGlucoseDataRow]? {
        let glucoseSamples = await getGlucoseStorage().readingsBetween(startDate: at - (Double(numberOfRows) * timeStep + timeStep), endDate: at)
        let eventTimes = (0..<numberOfRows).map({ at - Double($0) * timeStep }).reversed()

        // glucose sample sanity checks
        guard let first = glucoseSamples.first, let last = glucoseSamples.last else {
            return nil
        }
        guard at.timeIntervalSince(last.date) < timeStep, at.timeIntervalSince(first.date) > timeStep * Double(numberOfRows-1) else {
            return nil
        }
        
        guard glucoseSamples.count >= minNumberOfGlucoseSamples else {
            return nil
        }
        
        var addedGlucoseDataFrame: [AddedGlucoseDataRow] = []
        for eventTime in eventTimes {
            let iob = await getInsulinStorage().insulinOnBoard(at: eventTime)
            let insulinDelivered = await getInsulinStorage().insulinDelivered(startDate: eventTime - timeStep, endDate: eventTime)
            guard let glucose = glucoseIterpolation(samples: glucoseSamples, eventTime: eventTime) else {
                return nil
            }
            addedGlucoseDataFrame.append(AddedGlucoseDataRow(eventTime: eventTime, glucose: glucose, insulinDelivered: insulinDelivered, insulinOnBoard: iob))
        }
        precondition(addedGlucoseDataFrame.count == numberOfRows)
        return addedGlucoseDataFrame
    }
}

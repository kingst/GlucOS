//
//  DecimalPicker.swift
//  PickerTest
//
//  Created by Sam King on 1/13/24.
//

import SwiftUI

struct DecimalSetting: Hashable, Identifiable, Equatable {
    let id: String
    let string: String
    let value: Double
    let units: String
    
    init(value: Double, units: String) {
        self.value = value
        self.units = units
        let string = DecimalSetting.string(value: value, units: units)
        self.id = string
        self.string = string
    }
    
    static func string(value: Double, units: String) -> String {
        let decimal: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }()
        
        let numberString = decimal.string(from: NSNumber(value: value)) ?? String(format: "%0.2f", value)
        
        return "\(numberString) \(units)"
    }
    
    static func == (lhs: DecimalSetting, rhs: DecimalSetting) -> Bool {
        return lhs.id == rhs.id
    }
}

struct DecimalPicker: View {
    let title: String
    @Binding var selection: DecimalSetting
    let items: [DecimalSetting]
    @Binding var hasModifications: Bool
    
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(items) { item in
                Text(item.string).tag(item)
            }
        }
        .onChange(of: selection) { _ in
            hasModifications = true
        }
    }
}

struct DecimalPickerWithNotSet: View {
    let title: String
    @Binding var selection: DecimalSetting?
    let items: [DecimalSetting]
    @Binding var hasModifications: Bool
    
    var body: some View {
        Picker(title, selection: $selection) {
            Text("Not set").tag(nil as DecimalSetting?)
            ForEach(items) { item in
                Text(item.string).tag(Optional(item))
            }
        }
        .onChange(of: selection) { _ in
            hasModifications = true
        }
    }
}

struct DecimalSettingScheduleView: View {
    @ObservedObject var schedule: DecimalSettingSchedule
    let items: [DecimalSetting]
    @Binding var hasModifications: Bool
    
    var body: some View {
        let selections = [$schedule.midnightToFour,
                          $schedule.fourToEight,
                          $schedule.eightToTwelve,
                          $schedule.twelveToSixteen,
                          $schedule.sixteenToTwenty,
                          $schedule.twentyToTwentyFour]
        let times = [(0,4), (4,8), (8,12), (12,16), (16,20), (20,24)].map { rangeString($0) }
        let timesAndSelections = zip(times, selections).map { $0 }
        ForEach(timesAndSelections, id: \.0) { item in
            DecimalPickerWithNotSet(title: item.0, selection: item.1, items: items, hasModifications: $hasModifications)
        }
    }
    
    func format(hour: Int) -> String {
        let calendar = Calendar.current
        
        let today = Date()
        
        var start = DateComponents()
        start.year = calendar.component(.year, from: today)
        start.month = calendar.component(.month, from: today)
        start.day = calendar.component(.day, from: today)
        start.hour = hour
        
        return calendar.date(from: start)?.formatted(date: .omitted, time: .shortened) ?? "\(hour)"
    }
    
    func rangeString(_ times: (Int, Int)) -> String {
        return format(hour: times.0) + " - " + format(hour: times.1)
    }
}

#Preview {
    DecimalPicker(title: "Preview", selection: .constant(DecimalSetting(value: 1.0, units: "U")), items: [DecimalSetting(value: 1.0, units: "U"), DecimalSetting(value: 2.0, units: "U")], hasModifications: .constant(false))
}

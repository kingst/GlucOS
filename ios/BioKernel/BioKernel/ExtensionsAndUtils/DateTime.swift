//
//  DateTime.swift
//  BioKernel
//
//  Created by Sam King on 11/11/23.
//

import Foundation

protocol DateTime {
    func now() -> Date
    func parse(_ dateString: String, formatter: DateTimeFormat) -> Date?
}

enum DateTimeFormat {
    case humanReadable
    
    static var humanReadableFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"

        return formatter
    }
}

class ClockDateTime: DateTime {
    static let shared = ClockDateTime()
    
    func now() -> Date {
        return Date()
    }
    
    func parse(_ dateString: String, formatter: DateTimeFormat) -> Date? {
        switch formatter {
        case .humanReadable:
            return DateTimeFormat.humanReadableFormatter.date(from: dateString)
        }
    }
}

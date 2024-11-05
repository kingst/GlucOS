//
//  DiagnosticLog.swift
//  LoopKit
//
//  Created by Darin Krauss on 6/12/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import LoopKit

public class DiagnosticLog {

    private let subsystem: String

    private let category: String

    private let log: OSLog

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    public func debug(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .debug, args)
    }

    public func info(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .info, args)
    }

    public func `default`(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .default, args)
    }

    public func error(_ message: StaticString, _ args: CVarArg...) {
        log(message, type: .error, args)
    }

    private func log(_ message: StaticString, type: OSLogType, _ args: [CVarArg]) {
        switch args.count {
        case 0:
            os_log(message, log: log, type: type)
        case 1:
            os_log(message, log: log, type: type, args[0])
        case 2:
            os_log(message, log: log, type: type, args[0], args[1])
        case 3:
            os_log(message, log: log, type: type, args[0], args[1], args[2])
        case 4:
            os_log(message, log: log, type: type, args[0], args[1], args[2], args[3])
        case 5:
            os_log(message, log: log, type: type, args[0], args[1], args[2], args[3], args[4])
        default:
            os_log(message, log: log, type: type, args)
        }

        guard let sharedLogging = SharedLogging.instance else {
            return
        }
        sharedLogging.log(message, subsystem: subsystem, category: category, type: type, args)
    }

}

extension DiagnosticLog {

    convenience init(category: String) {
        self.init(subsystem: "com.getgrowthmetrics.BioKernel", category: category)
    }

}

public class SharedLogging {

    /// A shared, global instance of Logging.
    public static var instance: Logging? = LoggingServicesManager()

}

public protocol Logging {

    /// Log a message for the specific subsystem, category, type, and optional arguments. Modeled after OSLog, but
    /// captures all of the necessary data in one function call per message. Note that like OSLog, the message may
    /// contain "%{public}" and "%{private}" string substitution qualifiers that should be observed based upon the
    /// OSLog rules. That is, scalar values are considered public by default, while strings and objects are considered
    /// private by default. The explicitly specified qualifiers override these defaults.
    ///
    /// - Parameters:
    ///   - message: The message to log with optional string substitution. Note that like OSLog, it make contain "%{public}"
    ///     and "%{private}" string substitution qualifiers that should be observed based upon the OSLog rules.
    ///   - subsystem: The subsystem logging the message. Typical the reverse dot notation identifier of the framework.
    ///   - category: The category for the message. Typically the class or extension name.
    ///   - type: The type of the message. One of OSLogType.
    ///   - args: Optional arguments to be substituted into the string.
    func log(_ message: StaticString, subsystem: String, category: String, type: OSLogType, _ args: [CVarArg])

}

public protocol LoggingService: Logging, Service {}

final class LoggingServicesManager: Logging {

    private var loggingServices = [LoggingService]()

    init() {}

    func addService(_ loggingService: LoggingService) {
        loggingServices.append(loggingService)
    }

    func restoreService(_ loggingService: LoggingService) {
        loggingServices.append(loggingService)
    }

    func removeService(_ loggingService: LoggingService) {
        loggingServices.removeAll { $0.serviceIdentifier == loggingService.serviceIdentifier }
    }

    func log (_ message: StaticString, subsystem: String, category: String, type: OSLogType, _ args: [CVarArg]) {
        loggingServices.forEach { $0.log(message, subsystem: subsystem, category: category, type: type, args) }
    }
    
}

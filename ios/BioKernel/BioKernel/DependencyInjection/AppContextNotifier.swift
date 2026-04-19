//
//  AppContextNotifier.swift
//  BioKernel
//
//  Narrow callback surface for services that need to notify the watch that
//  shared app context has changed. Breaks the cycle between storage services
//  (Glucose/Insulin) and WatchComms.
//

import Foundation

public protocol AppContextNotifier: AnyObject, Sendable {
    func updateAppContext() async
}

#!/bin/bash
xcodebuild test -workspace MetabolicOS.xcworkspace \
	   -scheme BioKernel \
	   -destination 'platform=iOS Simulator,name=iPhone 16' \
    | xcpretty

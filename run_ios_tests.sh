#!/bin/bash
xcodebuild test -workspace ios/MetabolicOS.xcworkspace \
	   -scheme BioKernel \
	   -destination 'platform=iOS Simulator,name=iPhone 16' \
    | xcpretty

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=DerivedData/route-checks-build
mkdir -p "$build"
xcrun swiftc -parse-as-library -emit-library -static -emit-module -module-name HHTCore \
    -emit-module-path "$build/HHTCore.swiftmodule" ThirdParty/HHTCore/Sources/HHTCore/*.swift -o "$build/libHHTCore.a"
xcrun swiftc -parse-as-library -I "$build" -L "$build" -lHHTCore \
    LifeMem/{LocationPoint,RouteModels,AutomaticTrips,SegmentBuilder,TimelineSegment,Routes,RouteSummary,SavedPlace,PlaceResolver,PlaceSuggestions,RouteAnalytics,RouteBehavior,RouteInsights,RouteMapProjection,NoteTranscript}.swift \
    tests/RouteChecks.swift -o "$build/route-checks"
"$build/route-checks"

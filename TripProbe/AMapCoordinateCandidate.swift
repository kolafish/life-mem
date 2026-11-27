// WGS-84-to-GCJ-02 approximation adapted from https://github.com/wandergis/coordTransform.
// Copyright (c) 2015 记忆的残骸
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import CoreLocation
import Foundation

enum AMapCoordinateCandidate {
    // This is a limit for the diagnostic preview, not a test for regional map coverage.
    static func converted(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D? {
        guard (3.86...53.55).contains(coordinate.latitude), (73.66...135.05).contains(coordinate.longitude) else { return nil }

        let east = coordinate.longitude - 105
        let north = coordinate.latitude - 35
        let radians = coordinate.latitude * .pi / 180
        let semiMajorAxis = 6_378_245.0
        let eccentricitySquared = 0.00669342162296594323
        let sine = sin(radians)
        let ellipsoidFactor = 1 - eccentricitySquared * sine * sine
        let primeVerticalRadius = semiMajorAxis / sqrt(ellipsoidFactor)
        let meridianRadius = primeVerticalRadius * (1 - eccentricitySquared) / ellipsoidFactor
        let latitudeOffset = northOffset(east: east, north: north) / meridianRadius * 180 / .pi
        let longitudeOffset = eastOffset(east: east, north: north) / (primeVerticalRadius * cos(radians)) * 180 / .pi
        return .init(latitude: coordinate.latitude + latitudeOffset, longitude: coordinate.longitude + longitudeOffset)
    }

    private static func northOffset(east: Double, north: Double) -> Double {
        let polynomial = -100 + 2 * east + 3 * north + 0.2 * north * north + 0.1 * east * north + 0.2 * sqrt(abs(east))
        let northWaves = 20 * sin(north * .pi) + 40 * sin(north * .pi / 3)
            + 160 * sin(north * .pi / 12) + 320 * sin(north * .pi / 30)
        return polynomial + (sharedWaves(east: east) + northWaves) * 2 / 3
    }

    private static func eastOffset(east: Double, north: Double) -> Double {
        let polynomial = 300 + east + 2 * north + 0.1 * east * east + 0.1 * east * north + 0.1 * sqrt(abs(east))
        let eastWaves = 20 * sin(east * .pi) + 40 * sin(east * .pi / 3)
            + 150 * sin(east * .pi / 12) + 300 * sin(east * .pi / 30)
        return polynomial + (sharedWaves(east: east) + eastWaves) * 2 / 3
    }

    private static func sharedWaves(east: Double) -> Double {
        20 * sin(6 * east * .pi) + 20 * sin(2 * east * .pi)
    }
}

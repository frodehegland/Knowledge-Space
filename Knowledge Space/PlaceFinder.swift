import Foundation
import CoreLocation

/// One-shot place finding for the Mac, mirroring the phone's: current
/// location, reverse-geocoded to the most natural short name —
/// sublocality, locality, and country where the placemark has them
/// ("Wimbledon, London, United Kingdom"), per the format's location
/// convention. A desk machine rarely moves, but a laptop writes from
/// the café too.
final class PlaceFinder: NSObject, CLLocationManagerDelegate {
    var onPlace: (@MainActor (String) -> Void)?
    private let manager = CLLocationManager()

    func begin() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task {
            guard let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(location).first else { return }
            let parts = [placemark.subLocality, placemark.locality, placemark.country]
                .compactMap { $0 }
            let place = parts.isEmpty
                ? (placemark.name ?? placemark.administrativeArea ?? "")
                : parts.joined(separator: ", ")
            guard !place.isEmpty else { return }
            await MainActor.run { [onPlace] in onPlace?(place) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No place, no field — the note simply travels without one.
    }
}

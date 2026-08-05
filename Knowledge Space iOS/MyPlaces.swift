import SwiftUI
import CoreLocation
import Observation

/// The places the user has named — the office, the favourite coffee
/// shop — each pinned to one precise fix taken at the moment of naming.
/// Naming is the permission: only within a short walk of a named place
/// does a note's stamp say more than the neighbourhood. The pin stays
/// in this file on this phone; a note carries only the words.
@MainActor @Observable
final class MyPlaces {
    static let shared = MyPlaces()

    nonisolated struct Record: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var name: String        // the name the user chose
        var latitude: Double
        var longitude: Double
        var tail: String        // the surroundings as naming found them:
                                // "Wimbledon, London, United Kingdom"

        /// The whole stamp a note carries from here — the chosen name,
        /// then the surroundings, so the Mac's country grouping and the
        /// place directory read it like any other place.
        var stamp: String {
            tail.isEmpty ? name : "\(name), \(tail)"
        }

        var location: CLLocation {
            CLLocation(latitude: latitude, longitude: longitude)
        }
    }

    /// How close a capture must be for a named place to claim it —
    /// generous enough for the hundred-metre fix a note takes, small
    /// enough that the café across town keeps its own name.
    private static let radius: CLLocationDistance = 150

    private(set) var records: [Record] = []

    /// The community folder's copy, once a folder is open — the readable
    /// registry the Mac reads to know a nickname's locality. Naming still
    /// happens only on the phone.
    private var communityURL: URL?

    /// The file name the Mac looks for in the community folder.
    nonisolated static let communityFileName = "Localities.json"

    init() {
        load()
    }

    /// Points the store at an open community folder: any records already
    /// there (from another phone) are folded in, then the merged registry
    /// is published so the folder holds the fullest picture.
    func attach(folder: URL) {
        let url = folder.appendingPathComponent(Self.communityFileName)
        communityURL = url
        if let data = try? Data(contentsOf: url),
           let arrived = try? JSONDecoder().decode([Record].self, from: data) {
            for record in arrived where !records.contains(where: { $0.id == record.id }) {
                records.append(record)
            }
            records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        save()
    }

    /// The stamp for a capture made near a named place — the nearest
    /// name within the radius — or nil when the user is nowhere they
    /// have named and the note keeps its neighbourhood stamp.
    func stamp(near location: CLLocation) -> String? {
        records
            .map { ($0, $0.location.distance(from: location)) }
            .filter { $0.1 <= Self.radius }
            .min { $0.1 < $1.1 }?
            .0.stamp
    }

    func add(name: String, location: CLLocation, tail: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        records.append(Record(id: UUID(),
                              name: trimmed,
                              latitude: location.coordinate.latitude,
                              longitude: location.coordinate.longitude,
                              tail: tail))
        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func rename(_ record: Record, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].name = trimmed
        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(_ record: Record) {
        records.removeAll { $0.id == record.id }
        save()
    }

    // MARK: Persistence

    private nonisolated static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("MyPlaces.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        // Publish the readable registry into the community folder too, so
        // the Mac can refer to the nicknames and know where they are.
        if let communityURL {
            try? data.write(to: communityURL, options: .atomic)
        }
    }
}

/// One-shot precise fix for naming a place: best accuracy, asked for
/// only in this deliberate moment — everyday note capture stays at a
/// hundred metres and never needs more.
private final class PreciseFixFinder: NSObject, CLLocationManagerDelegate {
    var onFix: (@MainActor (CLLocation) -> Void)?
    var onFailure: (@MainActor () -> Void)?
    private let manager = CLLocationManager()

    func begin() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { await MainActor.run { [onFix] in onFix?(location) } }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { await MainActor.run { [onFailure] in onFailure?() } }
    }
}

/// My Places: the user's named spots, and the door to naming a new one.
/// Naming takes one precise fix — the only moment the app asks exactly
/// where the phone is — then the chosen name stands in for the
/// neighbourhood on every note made there.
struct MyPlacesView: View {
    /// Opened straight into naming from Settings ("Name Present
    /// Locality"): take the precise fix at once so the user lands on the
    /// name field, without a second tap.
    var startNaming = false

    @Environment(\.dismiss) private var dismiss

    @State private var places = MyPlaces.shared
    @State private var finder = PreciseFixFinder()
    @State private var hasAutoStarted = false
    @State private var locating = false
    @State private var namingFix: CLLocation?
    @State private var namingTail = ""
    @State private var name = ""
    @State private var renaming: MyPlaces.Record?
    @State private var renameText = ""
    @State private var errorText: String?

    /// A fix looser than this cannot tell one coffee shop from the
    /// next — usually the sign that Precise Location is off.
    private static let acceptableAccuracy: CLLocationAccuracy = 250

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        beginNaming()
                    } label: {
                        if locating {
                            Label {
                                Text("Finding This Place…")
                            } icon: {
                                ProgressView()
                            }
                        } else {
                            Label("Name This Place", systemImage: "mappin.and.ellipse")
                        }
                    }
                    .disabled(locating)
                } footer: {
                    Text("Naming takes one precise location fix, here and now. Named places stay on this phone — a note made near one carries the name you chose, never the location itself.")
                }
                if !places.records.isEmpty {
                    Section("Named Places") {
                        ForEach(places.records) { record in
                            Button {
                                renameText = record.name
                                renaming = record
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.name)
                                        .foregroundStyle(.primary)
                                    if !record.tail.isEmpty {
                                        Text(record.tail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    places.remove(record)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("My Places")
            // From Settings' "Name Present Locality", the fix is taken the
            // moment the screen appears, so naming here is immediate.
            .onAppear {
                guard startNaming, !hasAutoStarted else { return }
                hasAutoStarted = true
                beginNaming()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Name This Place", isPresented: Binding(
            get: { namingFix != nil },
            set: { if !$0 { namingFix = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { saveNamed() }
            Button("Cancel", role: .cancel) { namingFix = nil }
        } message: {
            Text(namingTail.isEmpty
                 ? "Give this spot the name your notes should carry."
                 : "You are near \(namingTail). Give this spot the name your notes should carry.")
        }
        .alert("Rename Place", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { places.rename(renaming, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Could Not Pin This Place", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func beginNaming() {
        locating = true
        finder.onFix = { location in
            // Reduced accuracy delivers a fix kilometres wide — honest
            // to refuse than to pin the wrong street.
            guard location.horizontalAccuracy <= Self.acceptableAccuracy else {
                locating = false
                errorText = "The location fix was too approximate to pin a place. If Precise Location is off for this app in Settings, turn it on and try again."
                return
            }
            Task { @MainActor in
                let placemark = try? await CLGeocoder()
                    .reverseGeocodeLocation(location).first
                let parts = [placemark?.subLocality, placemark?.locality, placemark?.country]
                    .compactMap { $0 }
                namingTail = parts.joined(separator: ", ")
                // The placemark often knows the venue — offer it as a
                // starting point; the user's own words replace it.
                name = placemark?.name ?? ""
                locating = false
                namingFix = location
            }
        }
        finder.onFailure = {
            locating = false
            errorText = "No location fix arrived. Check that this app may use your location, and try again."
        }
        finder.begin()
    }

    private func saveNamed() {
        guard let fix = namingFix else { return }
        places.add(name: name, location: fix, tail: namingTail)
        namingFix = nil
        name = ""
        namingTail = ""
    }
}

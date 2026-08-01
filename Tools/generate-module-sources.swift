#!/usr/bin/env swift
//
//  generate-module-sources.swift
//  Knowledge Space
//
//  Regenerates Views/ModuleSources.json — the build-time snapshot of every
//  view module's Swift source that the app exports when a community member
//  shares a view. The snapshot must match the source it stands for, or a
//  reader who edits a view and exports it hands out stale code. Rather than
//  trust anyone to keep the JSON in step by hand, this script rebuilds it
//  from the source files themselves.
//
//  Run it directly:
//
//      swift Tools/generate-module-sources.swift
//
//  or, better, wire it as a pre-build Run Script phase so the snapshot can
//  never drift (see Tools/README-module-sources.md). It rewrites the file
//  only when its contents change, so a build phase adds no git churn and no
//  rebuild loop.
//
//  A module file is any Views/*.swift that declares `static let module =
//  LibraryViewModule(...)`. The module's id is read from that initializer —
//  never from elsewhere in the file, where a ForEach's `id:` or a Label's
//  `systemImage:` would otherwise be mistaken for it.
//

import Foundation

// MARK: - Locating the Views directory

/// The Views directory, resolved so the script works both by hand and as
/// an Xcode build phase: an explicit argument wins, then Xcode's SRCROOT,
/// then a path relative to this script file.
func resolveViewsDirectory() -> URL {
    let fm = FileManager.default
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
        return URL(fileURLWithPath: srcRoot, isDirectory: true)
            .appendingPathComponent("Knowledge Space/Views", isDirectory: true)
    }
    // …/Tools/generate-module-sources.swift → …/Knowledge Space/Views
    let scriptURL = URL(fileURLWithPath: #filePath)
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let candidate = repoRoot.appendingPathComponent("Knowledge Space/Views", isDirectory: true)
    if fm.fileExists(atPath: candidate.path) { return candidate }
    return candidate
}

// MARK: - Reading a module's declared id

/// The id a file's `LibraryViewModule(...)` initializer declares, or nil if
/// the file declares no module. Extraction is scoped to the initializer so
/// the many `id:`/`systemImage:` in a view body are never mistaken for the
/// module's own — the same scoping the app's importer uses.
func moduleID(in source: String) -> String? {
    guard source.contains("static let module"),
          let declStart = source.range(of: "LibraryViewModule(") else { return nil }
    let declaration = String(source[declStart.lowerBound...])
    guard let regex = try? NSRegularExpression(pattern: "id:\\s*\"([^\"]+)\""),
          let match = regex.firstMatch(in: declaration,
                                       range: NSRange(declaration.startIndex..., in: declaration)),
          let range = Range(match.range(at: 1), in: declaration) else { return nil }
    return String(declaration[range])
}

// MARK: - The snapshot

struct Entry: Codable { let file: String; let source: String }
struct Snapshot: Codable { let format: String; let modules: [String: Entry] }

let viewsDir = resolveViewsDirectory()
let fm = FileManager.default

guard let names = try? fm.contentsOfDirectory(atPath: viewsDir.path) else {
    FileHandle.standardError.write(Data("generate-module-sources: no Views directory at \(viewsDir.path)\n".utf8))
    exit(1)
}

var modules: [String: Entry] = [:]
for name in names where name.hasSuffix(".swift") {
    let fileURL = viewsDir.appendingPathComponent(name)
    guard let source = try? String(contentsOf: fileURL, encoding: .utf8),
          let id = moduleID(in: source) else { continue }
    if let clash = modules[id] {
        FileHandle.standardError.write(Data(
            "generate-module-sources: id \"\(id)\" is declared by both \(clash.file) and \(name)\n".utf8))
        exit(1)
    }
    modules[id] = Entry(file: name, source: source)
}

let snapshot = Snapshot(format: "origami-view-sources/1", modules: modules)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
guard let data = try? encoder.encode(snapshot) else {
    FileHandle.standardError.write(Data("generate-module-sources: could not encode snapshot\n".utf8))
    exit(1)
}

// Rewrite only on change: a no-op build phase must not dirty the tree or
// trigger another build.
let outURL = viewsDir.appendingPathComponent("ModuleSources.json")
if let existing = try? Data(contentsOf: outURL), existing == data {
    print("generate-module-sources: \(modules.count) modules, already current.")
    exit(0)
}
do {
    try data.write(to: outURL, options: .atomic)
    print("generate-module-sources: wrote \(modules.count) modules to ModuleSources.json.")
} catch {
    FileHandle.standardError.write(Data("generate-module-sources: could not write ModuleSources.json: \(error)\n".utf8))
    exit(1)
}

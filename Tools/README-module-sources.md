# Keeping ModuleSources.json fresh

`Knowledge Space/Views/ModuleSources.json` is the build-time snapshot of every
view module's Swift source. The app reads it to **export** a view a community
member wants to share (Settings ▸ Edit Views). If the snapshot falls behind the
source, people export stale code — and a module missing from the snapshot can't
be shared at all.

`Tools/generate-module-sources.swift` rebuilds the snapshot from the source
files, so nobody has to keep it in step by hand.

## By hand

Run this whenever a view module changes, before committing:

```sh
swift Tools/generate-module-sources.swift
```

It rewrites the JSON only when the contents actually change, and prints what it
did. Commit the result alongside the module edit.

## Automatic (recommended): a pre-build Run Script phase

Wire it as a build phase and the snapshot can never drift — every build
regenerates it first, and the "rewrite only on change" guard means a build with
no module edits touches nothing (no git churn, no rebuild loop).

In Xcode:

1. Select the **Knowledge Space** target ▸ **Build Phases**.
2. **+** ▸ **New Run Script Phase**. Drag it **above** *Compile Sources*.
3. Name it "Generate Module Sources" and give it this script:

   ```sh
   swift "$SRCROOT/Tools/generate-module-sources.swift"
   ```

4. Under **Input Files**, add `$(SRCROOT)/Knowledge Space/Views` and under
   **Output Files** add `$(SRCROOT)/Knowledge Space/Views/ModuleSources.json`,
   so Xcode only reruns it when a Views file changes.
5. If **User Script Sandboxing** (`ENABLE_USER_SCRIPT_SANDBOXING`) is on for the
   target, this phase needs to write into the source tree — set it to **No**, or
   grant the phase the necessary access.

The script picks the Views directory from `$SRCROOT` when Xcode runs it, from a
path argument when given one, or from its own location otherwise.

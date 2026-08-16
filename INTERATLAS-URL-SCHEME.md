# Interatlas — receiving Interatlas Links

*Found while wiring Knowledge Space's "Open Source" (16 August 2026):
clicking an image's Interatlas citation should recreate the scene in
Interatlas, but macOS refused the hand-off — "The application
'Interatlas' cannot open the specified document or URL." Verified
against /Applications/Interatlas.app: the app declares **no URL scheme
and no associated domain**, so the system has no door to deliver a
link through, however the sender tries. The link format itself is
fine; only the receiving side is missing.*

## 1. Declare the `interatlas://` scheme (the one-entry fix)

Info.plist:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.augmentedtext.interatlas.link</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>interatlas</string>
    </array>
  </dict>
</array>
```

And in the app, handle arrivals (SwiftUI):

```swift
.onOpenURL { url in
    // interatlas://link.augmentedtext.com/v1/earth?rung=…&layers=…
    // Same path and query as the https form — reuse the v1 parser;
    // only the scheme differs.
}
```

**Convention senders will use** (Knowledge Space already does): the
https link with its scheme swapped, everything else intact —

```
https://link.augmentedtext.com/v1/earth?rung=oceans&layers=whales,…
interatlas://link.augmentedtext.com/v1/earth?rung=oceans&layers=whales,…
```

so one parser serves both forms. Knowledge Space probes for a
registered `interatlas://` handler first and uses it the moment this
ships — no change needed on the sending side.

## 2. Register the universal link domain (the full fix, later)

With the scheme in place, links still open in the browser when clicked
in Safari, Mail, or anywhere that doesn't know the convention. The
system-wide cure:

- Interatlas entitlement: `com.apple.developer.associated-domains` →
  `applinks:link.augmentedtext.com`
- On the server: `https://link.augmentedtext.com/.well-known/apple-app-site-association`
  naming the app id and the `/v1/*` paths.

Then every `link.augmentedtext.com` URL routes to Interatlas wherever
it is clicked, and step 1's scheme remains as the explicit form.

## Until either lands

Knowledge Space's Open Source falls back gracefully: it puts the link
on the clipboard and brings Interatlas forward, saying so — no dead
alert. Remove nothing when the scheme ships; the probe order takes
care of itself.

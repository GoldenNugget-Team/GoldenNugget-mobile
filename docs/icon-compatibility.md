# Icon Composer compatibility

The current icon is the modern `.icon` document introduced in mobile commit
`c3c5674`, using the original nugget and squircle PNGs. It is compiled as an
icon stack, including light, dark and tinted appearances.

Xcode 26.6's `actool` rejects two authoring settings from that document:

- Top-level `features: ["refractivity", "specular-location"]`.
- The Container group's `specular: "outside"` override.

Each independently reproduces the failure to open `AppIcon.icon`, followed by
the `NSPlaceholderArray` nil-object exception. Removing those two settings
allows the complete document to compile. Image bytes, layer positions, fill
gradients, blends, glass flags, translucency, shadow and refractivity settings
are preserved. The unsupported specular override falls back to the compiler's
default; this is not a replacement with the historical light/dark PNG artwork.

Both GitHub Actions workflows check for Xcode 26+, iOS SDK 26+, and Swift 6+
before compiling. The Assets.car workflow requires the dark appearance check
to pass before uploading its artifact.

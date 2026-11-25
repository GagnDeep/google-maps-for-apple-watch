# Contributing to Wayfinder

Thanks for helping make the best maps app for Apple Watch! 🎉

## Getting set up
1. Follow the [install guide](README.md#install-on-your-apple-watch-with-xcode). The Simulator needs no signing at all.
2. The Xcode project is generated from `project.yml`. If you add files or change settings, run `xcodegen generate`, and commit both `project.yml` and `Wayfinder.xcodeproj`.
3. **Never commit `Config/Signing.local.xcconfig`, `.p8`/`.p12` files, or provisioning profiles.** They are git-ignored for a reason.

## Good first contributions
- Bugs where Google responses aren't parsed correctly in your country or language (include the place or route).
- Translations, accessibility (VoiceOver labels, Dynamic Type), and haptic or voice tuning.
- Items from the [roadmap](README.md#roadmap).

## Pull requests
- Keep PRs focused, and describe what you tested (Simulator or a real watch, which watchOS).
- Include a screenshot or short clip for UI changes.
- Match the existing style: Swift + SwiftUI, `@Observable` models, no third-party dependencies.

## Reporting a bug
Open an issue with your watch model, watchOS version, what you did, what you expected, and what happened.
Leave out personal location data you don't want public.

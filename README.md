# DataManager Dynamic Island — experimental build

Public macOS/iOS build project for a **Live Activity demo** and an unsigned `libIslandHook.dylib`.

**Important:** These files are **not a working DataManager V3 patch**. The dylib exposes C symbols `KiraIslandStart`, `KiraIslandProgress`, and `KiraIslandFinish`; a verified integration into DataManager's own download progress events is still required. A standalone dylib cannot display Dynamic Island without a signed host app and embedded widget extension.

The workflow produces unsigned build components as GitHub Actions artifacts. Do not distribute an IPA or advertise a working tweak without signing and testing on an iPhone. This repository does not contain proprietary DataManager binaries or certificates.

Source layout: `Hook/` (dylib bridge), `Shared/` (ActivityKit model), `Widget/` (Live Activity UI), and `Demo/` (standalone real download test).

The actual Live Activity is driven by received bytes and expected bytes. Unknown totals show an indeterminate indicator. iOS can throttle updates when the host application is suspended.

Apple reference: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities

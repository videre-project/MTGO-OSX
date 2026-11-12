# Brand Assets

## Change Artwork

| Asset | Use | Source |
| --- | --- | --- |
| [MTGO.ico](MTGO.ico) | MTGO branding in the launcher; input for generated app and Wine icons. | Official MTGO ClickOnce client. |
| [MTGO-Background.jpg](MTGO-Background.jpg) | Launcher backdrop, cropped and shaded in SwiftUI. | [Official MTGO website](https://www.mtgo.com/images/home/home-bg.jpg?v=1699732767). |
| [DMG-Background.png](DMG-Background.png) | Installer instructions and macOS approval illustrations. | Composed installer artwork using MTGO branding and background imagery. |
| [Fonts/Inter.ttf](Fonts/Inter.ttf) | UI typography. | [Inter from Google Fonts](https://github.com/google/fonts/tree/main/ofl/inter); [Open Font License](Fonts/OFL.txt). |

| Change | Implementation |
| --- | --- |
| Charcoal app icon background and icon generation | [`//tools:icons`](../../tools/icons.swift); generates `GameIcon.icns`. |
| Launcher artwork cropping and shading | [LauncherBackground.swift](../Launcher/UI/LauncherBackground.swift). |
| DMG canvas and Finder icon positions | [dmg.swift](../../tools/dmg.swift). |

Update DMG canvas and icon positions when changing the installer layout. Generated `GameIcon.icns` is used by setup, gameplay, Wine windows and minimized thumbnails.

## Provenance

| Asset | Recorded identity |
| --- | --- |
| `MTGO.ico` | SHA-256: `32976494b413f5e7b95fcb547b03dd24846ce25701fb23d9da24a43a05e2aec4`. |
| `Fonts/Inter.ttf` | Git blob: `047c92f6e2212473dc436020afed689527076d44`. |

Magic: The Gathering artwork and trademarks belong to their respective owners. Inter's license is included in the app bundle.

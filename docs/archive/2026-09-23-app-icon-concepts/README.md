# Archived app icon concepts (2026-09-23)

The round that replaced the prompt-chevron icon. The first icon, a `>` over a
menu bar pill of four dots, read too much like a generic usage meter, so the
chevron went and the island became the object.

| File | Concept | Status |
|---|---|---|
| `previous-prompt-chevron.png` | The icon from 1.0.0 to 1.28.0: charcoal chevron, pill outline with four dots | Superseded |
| *(shipped)* | Status light: the island as a glossy slab with four glass lamps, Claude's lit | **Shipped** — `Scripts/appicon.swift` |
| `island-asking.png` | The island opened: an agent asking, with Allow ✓ and Deny ✕ | **Reserve**: liked, kept as a ready alternative. It's the more specific mark, but it gets busy at 16 px |

## Regenerating

`generator.swift` renders both concepts:

```bash
swift generator.swift ask island-asking.png
```

To ship `ask` instead, move its `case` body into `Scripts/appicon.swift` and
rebuild `Resources/AppIcon.icns` and the assets listed in that script's header.

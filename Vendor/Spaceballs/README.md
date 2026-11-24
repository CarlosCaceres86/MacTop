# Referencia de Mission Control

Origen: [Spaceballs](https://github.com/moltenbits/spaceballs/tree/bca247846e1fd7d0c916ca43a8f3398a5e9abf55), commit `bca247846e1fd7d0c916ca43a8f3398a5e9abf55`, licencia MIT ©2026 MoltenBits.

MacTop adapta en `Sources/MacTopSystem/MissionControlDesktopDrag.swift` la interpretación de las posiciones de miniaturas (origen en Dock hasta macOS 26 y centro en WindowManager desde 27), la espera de expansión y estabilidad de la barra y el flujo de arrastre nativo: agarrar, separar hacia abajo, acercarse a la barra de destino y mantener el arrastre antes de soltar. Referencias: `Sources/SpaceballsCore/MissionControlAX.swift`, `SpaceMovePlanner.swift` y `SpaceManager.swift` (traslado de Spaces).

La integración de MacTop resuelve miniaturas por pantalla e índice contra un inventario comprobado, sin nombres de escritorio en inglés. Valida ID y UUID, conserva un escritorio en origen, no crea hermanos ni elimina escritorios, garantiza `mouseUp` y observa el resultado. Permite una sola corrección de orden después de certificar una llegada al monitor correcto. El código completo de Spaceballs y su ejecutable no se incorporan como dependencia.

Conservar `LICENSE` al distribuir las adaptaciones. La compatibilidad física de la automatización debe comprobarse en el equipo y versión de macOS objetivo.

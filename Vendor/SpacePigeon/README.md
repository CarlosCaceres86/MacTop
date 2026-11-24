# spacectl vendorizado

Origen: [SpacePigeon v2.2.2](https://github.com/louivers/spacepigeon/tree/e61c5f24e2d7cb8a235a6bf0ff8d7ff80a056871), commit `e61c5f24e2d7cb8a235a6bf0ff8d7ff80a056871`, archivo `helper/spacectl.m` (helper 1.3.0).

MacTop conserva sólo `check`, `spaces`, `windows`, `move` y `version`. Elimina gestos, foco de Spaces, selftest que mueve ventanas y exploración de clases. Conserva AppKit y la operación bridged normal de SkyLight con SIP activo. No cambia SIP, TCC, preferencias ni relanza apps.

La salida `spaces` añade `uuid` por escritorio: UUID canónico no nulo del diccionario privado o `null` si falta o no es válido; nunca convierte el ID de sesión en UUID.

Modificaciones: mantiene ventanas pequeñas y pertenencia desconocida para que el adaptador pueda informar de ellas; exige escritorio ordinario, pertenencia exclusiva y PID/fecha de inicio antes de mover; verifica pertenencia exclusiva después. El adaptador Swift verifica además topología, identidad AX y posición física. Uso interno: `spacectl move WINDOW SPACE TIMEOUT_MS PID LAUNCH_EPOCH`.

Licencias incluidas: SpacePigeon (`LICENSE`, MIT ©2025 louivers), yabai (`LICENSE.yabai`, MIT ©2019 Åsmund Vikane) y ferry (`LICENSE.ferry`, MIT ©2019 Åsmund Vikane, ©2026 softmaxe), según las atribuciones del archivo original. La licencia histórica de ferry se obtuvo de [affaf2b2c21ae37aadcaafcf4d5421b016b3ad0e](https://github.com/softmaxe/ferry/blob/affaf2b2c21ae37aadcaafcf4d5421b016b3ad0e/LICENSE); el cambio posterior de ferry a AGPL no se incorpora. Copiar estas tres licencias al distribuir el ejecutable.

`scripts/build-helper.sh [ruta-de-salida]` compila offline para arm64 y x86_64 con macOS mínimo 26.4 y firma ad hoc por defecto. Las API privadas pueden cambiar: `check` sólo confirma presencia de la operación; la aceptación física en el MacBook exige la prueba documentada de movimiento entre pantallas.

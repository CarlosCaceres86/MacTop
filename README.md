# MacTop

Utilidad local de barra de menús para devolver las mismas ventanas abiertas a sus escritorios guardados. Conserva dos perfiles: **MacBook** y **MacBook + monitor**. No cierra ni relanza aplicaciones.

La primera beta privada es **MacTop 0.1.8**. La restauración automática funcionó en el MacBook de prueba con **macOS 26.6.2**, su pantalla integrada y un monitor externo en modo extendido. MacTop devuelve los escritorios originales que identifica con todas sus ventanas, recupera su orden y crea los destinos que aún faltan. Después coloca las ventanas individuales. La serie de diez ciclos sigue pendiente.

## Compilar

Requiere macOS y las herramientas de Xcode con Swift 6. El proyecto no descarga dependencias.

```sh
swift test
scripts/build-app.sh
```

El script crea `dist/MacTop.app`, `dist/MacTop-0.1.8-universal.zip` y la copia compatible `dist/MacTop-universal.zip`, con app y helper para Apple Silicon e Intel y firmas ad hoc locales verificadas. El mínimo del bundle es macOS 26.4. La firma es local, sin notarización.

## Instalar la beta 0.1.8

Descarga el ZIP universal de la primera beta. Si ya tienes MacTop, ciérrala antes de sustituirla en Aplicaciones. Abre la app y utiliza tus perfiles guardados. Al arrancar, MacTop comprueba si tiene permiso de Accesibilidad. Si falta, solicita el acceso a través de macOS. En el aviso, abre Ajustes del Sistema y activa MacTop. Cuando salgas de Ajustes o vuelvas a abrir el menú de MacTop, la app detectará el permiso y continuará con tu preferencia de restauración automática. [MacTop 0.1.8 · Beta 1](https://github.com/CarlosCaceres86/MacTop/releases/tag/v0.1.8-beta.1)

El icono verde muestra un MacBook delante de un monitor. Su versión monocroma abre el menú de la barra. La cabecera identifica el perfil detectado y cuántos escritorios numerados tiene el monitor externo o, si trabajas sólo con el portátil, su pantalla integrada. **Restaurar ahora** aplica esa distribución y **Guardar distribución para…** te muestra qué perfil vas a sustituir. Si abres el menú durante la detección, el perfil, el recuento de escritorios y la acción de guardado se actualizan en el menú abierto. Al guardar, la cabecera indica el perfil y cuántas ventanas quedaron pendientes. Se omite el resumen de restauración parcial con cero movimientos.

Cuando MacTop empieza a devolver un escritorio, crear uno que falta o colocar una ventana, un velo oscuro cubre las pantallas. En la integrada del MacBook aparece la fase actual. El velo deja pasar el ratón para que Mission Control pueda terminar los arrastres. Desaparece al terminar la comprobación o al interrumpirse la operación. Si todo está en su sitio, la pantalla permanece visible.

Cuando varios escritorios deban volver al externo, MacTop los arrastra en la misma vista de Mission Control. Comprueba cada traslado antes de empezar el siguiente. Si ya habías abierto Mission Control, lo deja abierto. Si cierras la vista entre dos traslados, MacTop se detiene y puedes continuar desde **Restaurar ahora**. Si uno de los escritorios que debe mover está activo, MacTop selecciona otro y puede reabrir la vista una vez que confirma ese cambio.

## Actualizar desde 0.1.0 y comprobar la corrección

1. Instala 0.1.8 siguiendo el apartado anterior. Los perfiles guardados con 0.1.0 se conservan.
2. Si ahora el monitor tiene un único escritorio y el perfil guardado tiene tres, usa **Restaurar ahora** antes de guardar. Guardar en ese estado sustituiría la referencia de tres escritorios por la distribución incompleta. Los perfiles antiguos no identifican los escritorios originales: MacTop recupera sus destinos por posición y crea sólo los que falten, conservando los demás escritorios y el perfil.
3. Cuando hayas recuperado y organizado la distribución completa que quieres conservar, elige **Guardar distribución para MacBook + monitor…** una sola vez. Esta acción memoriza los originales que macOS permite identificar. Guarda todos los escritorios presentes, también los vacíos: comprueba que la secuencia es la que quieres antes de hacerlo. Si sólo hay identificadores válidos durante la sesión, la devolución de esos originales requiere mantener MacTop abierto.
4. Desconecta el monitor y comprueba en Mission Control qué escritorios migran a la integrada. Reconecta y usa **Restaurar ahora**. Si los tres originales A, B y C siguen identificados en la integrada y el externo tiene un escritorio nuevo P, el resultado previsto es **A, B, C, P** en el externo, sin crear duplicados. Las ventanas ajenas al perfil que estuvieran en A, B o C viajan con su escritorio. P se conserva y el menú avisa del escritorio adicional; no es trabajo pendiente que provoque restauraciones repetidas.
5. Comprueba la pantalla, el orden y las ventanas en Mission Control, incluidos documentos con cambios sin guardar. Anota los recuentos de escritorios antes y después en ambas pantallas. Si falta evidencia inequívoca para devolver un original, comprueba el estado en la cabecera del menú. Una identidad ausente permite recuperar destinos por posición. Una devolución fallida o un cambio inesperado detiene la operación.
6. Repite **Restaurar ahora**. Una segunda restauración correcta debe indicar **0 movimientos**, sin volver a crear ni devolver escritorios. Si el resultado no coincide, conserva los perfiles, desactiva el automatismo y registra lo observado según las indicaciones de aceptación.

La creación se limita al déficit guardado y a un máximo de 16 escritorios ordinarios en el externo. No elimina escritorios migrados de la integrada para liberar capacidad. Si macOS rechaza una operación, la restauración se detiene y muestra el motivo.

La devolución de un escritorio completo requiere que las dos barras de Mission Control implicadas contengan únicamente escritorios numerados. Si hay un Space de pantalla completa o Split View mezclado en la barra de origen o destino, MacTop detiene ese traslado y muestra el motivo.

La serie completa de aceptación requiere el MacBook y el monitor reales.

## Primera prueba en el MacBook

1. Copia `MacTop-universal.zip` al MacBook, descomprímelo y coloca `MacTop.app` en Aplicaciones. Abre la app: aparece su icono en la barra de menús. Si macOS bloquea la compilación local, revisa su autorización en Ajustes del Sistema → Privacidad y seguridad.
2. En el aviso de Accesibilidad que aparece al abrir MacTop, abre Ajustes del Sistema y activa **MacTop**. Si cierras el aviso, **Permitir Accesibilidad…** aparece en el menú principal mientras falte el permiso. En una instalación nueva, la restauración automática empieza desactivada.
3. Sin el monitor, organiza las ventanas y sus escritorios. Elige **Guardar distribución para MacBook…**.
4. Conecta el monitor en modo extendido, organiza las ventanas en sus tres escritorios numerados y en la integrada. Elige **Guardar distribución para MacBook + monitor…** para memorizar también la identidad de los originales cuando esté disponible. Después, sal y vuelve a abrir MacTop para comprobar que los perfiles siguen disponibles.
5. Haz una ida y vuelta manual: desconecta, usa **Restaurar ahora**, comprueba la pantalla y el escritorio de cada ventana en Mission Control; reconecta y repite. Incluye un cambio de prueba sin guardar y comprueba que sigue presente. Una segunda restauración correcta debe indicar **0 movimientos**.

Sólo **Guardar distribución para…** sustituye una referencia. Nunca guardes para corregir una restauración parcial: primero devuelve las ventanas a la distribución deseada. **Más opciones → Abrir carpeta de perfiles** permite conservar una copia local antes de cambiarla. Un monitor externo diferente no sustituye el perfil del monitor guardado.

## Automatismo y aceptación

Tras comprobar la ida y vuelta manual, marca **Restauración automática**. La preferencia se conserva entre aperturas. MacTop espera tres lecturas coherentes de pantallas y escritorios y aplica el perfil correspondiente. Tras reposo o desbloqueo sólo restaura si cambió la configuración o quedó trabajo pendiente. La ruta manual y la automática usan la misma recuperación: devolver y ordenar originales identificados, crear sólo los destinos que aún falten y después restaurar las ventanas del perfil. Un cambio durante una operación espera su resultado y descarta los pasos restantes. Una pulsación o un arrastre fallido no se repite a ciegas. Los escritorios adicionales se conservan; su aviso, por sí solo, no mantiene trabajo pendiente. Mientras MacTop siga abierto, un gesto de escritorio fallido o cuya verificación sea incierta bloquea nuevos gestos automáticos para esa captura, también tras reposo, desbloqueo o reconexión. El menú indica que hace falta un reintento manual: usa **Restaurar ahora** cuando compruebes el estado. Guardar explícitamente una nueva distribución externa completa también habilita su recuperación. El perfil MacBook puede seguir restaurándose durante ese bloqueo.

Durante la reconexión automática, si llega otro aviso mientras MacTop devuelve escritorios o coloca ventanas, comprueba que siguen conectadas las mismas pantallas con la misma geometría. Si coinciden, continúa el lote en curso. Si la comprobación falla, interrumpe la operación. Cuando una ventana guardada aún no se puede identificar, MacTop vuelve a consultar el inventario durante un máximo de un segundo de espera. En cuanto la identifica, comprueba su destino y la coloca si hace falta. Cada ventana recibe como máximo un intento de movimiento durante la restauración.

Completa **diez ciclos de desconexión y reconexión**, comprobando los veinte extremos. Incluye reposo. Registra por extremo la versión del sistema, configuración, destinos esperados y observados, movimientos y cualquier intervención. Los veinte deben ser correctos, sin cierres, relanzados ni correcciones manuales. Prueba aparte una interrupción durante restauración y una ventana ambigua; deben dejar el trabajo accesible y explicar lo pendiente. La [lista de tareas](tasks/todo.md) detalla la aceptación.

Si falla, desactiva el automatismo, conserva los perfiles y anota la secuencia, el estado del menú y qué ventanas siguen fuera de su escritorio. Para comunicar el fallo bastan las apps y los números de escritorio; omite títulos, documentos y contenido personal. No envíes los perfiles completos. La estabilización admite hasta 30 intentos durante 15 segundos; una lectura ya en curso termina con su propio plazo antes de detenerse. Usa **Restaurar ahora** cuando la configuración sea estable.

## Componentes

[LayoutCoordinator](Sources/MacTopApp/LayoutCoordinator.swift) publica el perfil detectado y la fase de restauración a partir de las comprobaciones que ya realiza. [AppDelegate](Sources/MacTopApp/MacTopApp.swift) actualiza el menú y pasa la fase al [controlador del velo](Sources/MacTopApp/RestorationOverlayController.swift). Este último presenta un panel por pantalla. El coordinador es quien inicia y cancela los movimientos.

Para seguir una reconexión en el código, empieza en [LayoutCoordinator.recoverDesktops](Sources/MacTopApp/LayoutCoordinator.swift), que agrupa los traslados y termina la sesión antes de colocar ventanas individuales. [OrdinaryDesktopReturn.nextStep](Sources/MacTopCore/OrdinaryDesktopReturn.swift) elige el siguiente escritorio según su identidad y posición guardadas. [DesktopRecoverySession](Sources/MacTopSystem/DesktopRecoverySession.swift) recuerda quién abrió Mission Control y comprueba que la vista sigue disponible para el siguiente gesto. [DesktopPlacementExecution.execute](Sources/MacTopSystem/DesktopPlacementExecution.swift) verifica el monitor y el orden de llegada y, cuando es necesario, confirma el cambio de escritorio activo antes de reabrir la vista.

El helper deriva de [SpacePigeon v2.2.2](https://github.com/louivers/spacepigeon/tree/v2.2.2). Código fijado, cambios y licencias MIT de SpacePigeon, yabai y Ferry: [Vendor/SpacePigeon](Vendor/SpacePigeon/README.md). La automatización de Mission Control incorpora código MIT de [Spaceballs](Vendor/Spaceballs/README.md). Las cuatro licencias se incluyen en el bundle; la de Spaceballs se identifica como `Resources/ThirdParty/LICENSE.Spaceballs`.

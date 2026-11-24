# MacTop · Tareas de implementación

El [plan del MVP](plan.md) recoge el alcance. La primera prueba de 0.1.0 en el MacBook detectó un fallo de restauración al reconectar.

### Resultado del MacBook con macOS 26.6.2

El usuario tenía tres escritorios numerados en el monitor externo. Al desconectarlo, observó que macOS trasladaba sus escritorios al portátil. Al reconectarlo, el externo presentaba un único escritorio y MacTop 0.1.0 no logró devolver las ventanas a sus destinos. Se desconoce cuántos escritorios quedaron en la pantalla integrada al terminar ese ciclo. La serie de diez ciclos queda pendiente para la versión corregida.

Con 0.1.1 el usuario comunicó que la restauración parecía funcionar. Con 0.1.2 observó una mejora apreciable en la velocidad y pidió evitar las aperturas repetidas de Mission Control.

### Reconexión automática de 0.1.8 (9)

En el MacBook apareció el velo, quedaron escritorios o ventanas fuera de sitio y una restauración manual posterior completó la distribución. En 0.1.7 se reprodujeron en pruebas dos secuencias compatibles con esa observación.

- Dos avisos de pantalla durante el primer arrastre interrumpían la devolución del lote. Ahora se contrasta la configuración física con la observada al reconectar. Si coinciden las pantallas y su geometría, continúa la misma sesión de Mission Control. Un cambio físico o una lectura incierta siguen interrumpiendo la operación.
- Una ventana ausente del primer inventario podía reaparecer en la comprobación final sin recibir su movimiento. El coordinador aprovecha esa lectura y, si la ventana aún falta, admite hasta un segundo de espera adicional. Comprueba el movimiento antes de continuar y conserva el límite de un intento por ventana. Una ventana presente en varios escritorios queda pendiente sin añadir espera.
- En el Mac Studio pasaron 168 pruebas. En la reconexión simulada regresaron los tres originales en orden, se conservó el escritorio adicional del externo y se colocó la ventana tardía. Con el único monitor físico se verificó la comprobación de identidad, geometría y tipo de pantalla. El usuario confirmó que la restauración funciona en el MacBook con macOS 26.6.2. Queda pendiente la serie de diez ciclos.
- Se verificaron la firma local, las dos arquitecturas y la lectura del helper del ZIP de 0.1.8. SHA-256 `447a7c79b4acb0d264105993651fb4be75cd4debb64f82bd399f4dba40e6fe69`. [MacTop 0.1.8 · Beta 1](https://github.com/CarlosCaceres86/MacTop/releases/tag/v0.1.8-beta.1)

Para seguir el cambio en el código, el [coordinador](../Sources/MacTopApp/LayoutCoordinator.swift) gestiona los avisos y la espera, el [adaptador de macOS](../Sources/MacTopSystem/MacWindowSystem.swift) comprueba las pantallas físicas y las [pruebas de reconexión](../Tests/MacTopAppTests/LayoutCoordinatorTests.swift) reproducen los dos fallos.

### Actualización del menú abierto de 0.1.7 (8)

- Durante la detección, MacTop actualiza las filas del menú ya abierto cuando cambia el estado del coordinador. El nombre del perfil, los escritorios y el destino del botón Guardar se actualizan juntos. Una restauración parcial con cero ventanas movidas se omite tanto en el estado visible como en el recordatorio de la última restauración.
- Con 0.1.6, el menú del Mac Studio seguía indicando que estaba comprobando la configuración después de 12 segundos. Con 0.1.7 se comprobó el cambio de estado en la misma ventana del menú. En una prueba AppKit con un inventario simulado de MacBook y monitor se mostraron las dos pantallas y los tres escritorios externos, y se habilitó el guardado en el perfil externo.
- Pasaron 163 pruebas. Se verificaron el contenido y la firma del [ZIP universal de 0.1.7](../dist/MacTop-0.1.7-universal.zip). SHA-256 `de3ca764c1b062e6e6ae8008b934c2c0de2dab94f4e2e3487952179b80e8d574`.

### Guardado e icono de 0.1.6 (7)

- Se retiraron «Detalles del estado actual…» y «Último resultado…». La cabecera conserva el estado y un resumen breve. Guardar muestra el recuento de pendientes y conserva la confirmación previa para sustituir el perfil.
- En una prueba se guardaron 201 ventanas, 200 con asignación pendiente. Se conservó el perfil completo y se publicó un resumen de una línea. La suite suma 161 pruebas.
- En el Mac Studio con macOS 27.0.1 se verificó el icono verde en la fila de MacTop en Ajustes y en el aviso «Acerca de» de la app extraída. En dos aperturas independientes del aviso se comprobó el cierre con Escape y con Intro. El aspecto de la entrada de Accesibilidad en el MacBook con macOS 26.6.2 queda pendiente.
- El [ZIP de 0.1.6](../dist/MacTop-0.1.6-universal.zip) contiene la app y el helper universales. Se verificaron la firma y el recurso de icono declarado. SHA-256 `6d2d27352b2e39bcb5f80658423f9519b2e54a7319b68fb5c79e92633e95ba17`.

### Solicitud de Accesibilidad de 0.1.5 (6)

- Si falta el permiso al iniciar MacTop, la app solicita el aviso nativo de macOS. Al salir de Ajustes del Sistema o abrir el menú, vuelve a comprobar el permiso y empieza a supervisar las pantallas. La acción para abrir Accesibilidad está en el menú principal mientras haga falta.
- Pasaron 160 pruebas. Las dos nuevas ejercitan el inicio con permiso, el aviso descartado y la detección de una concesión simulada en la misma sesión. En el Mac Studio, una copia con identidad de prueba abrió el aviso real de macOS. Se comprobó que ofrecía abrir Ajustes y se descartó el aviso. La concesión desde Ajustes en el MacBook con 26.6.2 queda pendiente de verificación física.
- Se abrió el menú de la app extraída del [ZIP de 0.1.5](../dist/MacTop-0.1.5-universal.zip) y se verificaron la firma, las dos arquitecturas y el helper. SHA-256 `4a5b300cc8df58c00f443cac8e74736a754e02f5c012bc467e9ecfc95124af87`.

### Velo, icono y menú de 0.1.4 (5)

- La persona que usa el MacBook eligió el icono verde con el portátil y el monitor, el velo en ambas pantallas y un menú que omite la duración. El coordinador activa el velo al iniciar un movimiento y lo retira al terminar o al interrumpirse la restauración. El indicador de fase aparece una sola vez y da preferencia a la pantalla integrada. El menú reutiliza la lectura estable para identificar el destino de guardado y mostrar los escritorios numerados.
- Pasaron 158 pruebas, 38 de Core, 57 de System y 63 de App. Cubren el guardado con un monitor distinto al que se confirmó, la conservación del último resultado, la restauración sin movimientos y las interrupciones durante la colocación o el cierre de Mission Control.
- En el Mac Studio con macOS 27.0.1 y un monitor, una ventana de prueba recibió un clic real a través del velo. El indicador siguió visible al abrir Mission Control y las tres fases usaron el mismo panel. Al terminar, el velo desapareció y la aplicación que tenía el foco lo conservó. Queda por comprobar la cobertura de ambas pantallas durante el arrastre real de los tres escritorios del MacBook con macOS 26.6.2.
- Se abrió el menú de la app extraída del [ZIP de 0.1.4](../dist/MacTop-0.1.4-universal.zip) y se comprobaron sus acciones mediante Accesibilidad. Se verificaron la firma ad hoc, las dos arquitecturas, el mínimo 26.4, la lectura del helper y los diez tamaños del icono. SHA-256 `897a66b474ada48aa9df48d30662bbf235ff102302431afb4bd2d50983da0c2b`.

### Sesión compartida de 0.1.3 (4)

- En el Mac Studio con macOS 27.0.1, la sesión abrió Mission Control una vez, comprobó que la vista seguía disponible entre tres traslados simulados y la cerró una vez al finalizar. Cada traslado llegó a su posición en el monitor externo simulado. El orden y el escritorio activo del monitor físico coincidieron antes y después.
- En una segunda prueba se cerró la vista nativa entre gestos. MacTop detectó que había desaparecido y se detuvo antes del siguiente traslado simulado. Las pruebas automatizadas cubren también una vista inicialmente abierta por el usuario, la reapertura tras el cambio de escritorio activo, la combinación de creación y traslado, las cancelaciones y los errores de cierre.
- La suite conjunta pasó las 140 pruebas, 38 de Core, 57 del adaptador de sistema y 45 del coordinador. Quedan por medir la duración y el número de aperturas durante una reconexión física con los tres escritorios del MacBook. La prueba local utilizó un único monitor.
- Se extrajo el [ZIP de 0.1.3](../dist/MacTop-0.1.3-universal.zip) y se verificaron la firma ad hoc, las dos arquitecturas y el helper incluido. SHA-256 `3848c8c752a99db7b86a10924d420458b12ae5370415afffe30a76009cf505e4`.

### Rendimiento de 0.1.2 (3)

Durante la recuperación de los escritorios, MacTop lee la estructura de las pantallas y comprueba la identidad, el orden y el escritorio activo. Al llegar a la fase de ventanas, toma un inventario completo y confirma que las pantallas siguen coincidiendo. También se eliminó una espera después de que Foundation hubiera observado la terminación del helper. Se conservan las tres muestras de estabilidad y los tiempos del gesto nativo que funcionó en el MacBook.

En la suite conjunta pasaron **116 pruebas** en el Mac Studio. Son 38 de Core, 38 del adaptador de sistema y 40 del coordinador. Las regresiones cubren un cambio de pantalla entre la lectura de escritorios y la captura completa, la cancelación, la protección de perfiles ante una captura parcial y la salida del proceso auxiliar, incluso si hay que terminarlo tras el plazo máximo.

Se midieron cinco ejecuciones de distribución por variante, con el mismo helper. El coordinador devolvió tres escritorios identificados en dos pantallas simuladas y usó las pausas reales. Cada lectura consultó el adaptador real del Studio, que en ese momento veía un monitor, tres escritorios y 29 ventanas. La prueba excluyó el tiempo de detección del cable, las animaciones y el arrastre físico de Mission Control. Las ventanas del escenario ya estaban en su sitio.

| Variante | Mediana de la restauración | Inventarios completos de ventanas por ejecución |
| --- | ---: | ---: |
| 0.1.1 | 12,40 s | 25 |
| Lectura de escritorios separada | 9,87 s | 2 |
| 0.1.2 con la espera del helper corregida | 6,03 s | 2 |

En 0.1.2 hubo además 24 consultas de escritorios por ejecución. Las lecturas consumieron en conjunto una mediana de 1,87 s, frente a 8,26 s en 0.1.1. La duración física en el MacBook se puede contrastar en el menú con **Última restauración**.

### Validación local de 0.1.1 (2) del 24 de noviembre de 2026

- Pasaron las 99 pruebas de la suite conjunta en el Mac Studio con macOS 27.0.1. Son 36 de Core, 31 del adaptador de sistema y 32 del coordinador. Cubren la reconexión con un único escritorio externo, el perfil de 0.1.0 que requiere crear dos destinos y la devolución de tres originales con una ventana abierta después de la captura.
- En otra comprobación del planificador, 108 combinaciones de ubicación, orden, originales ausentes y escritorio externo adicional devolvieron los originales identificables a sus posiciones. Una segunda aplicación del plan requirió cero operaciones. Las dos pantallas de estas pruebas son simuladas.
- La revisión independiente encontró dos fallos. Un ID numérico que reaparecía con un UUID distinto podía hacer que se trasladara otro escritorio y un aviso de despertar podía repetir un gesto incierto. Los tests reprodujeron ambos casos antes de la corrección. El UUID observado ahora debe coincidir, y tras un gesto incierto el perfil externo requiere un reintento explícito mientras MacTop siga abierto. El perfil portátil sigue disponible.
- Con un único monitor real, Accesibilidad identificó el grupo de Mission Control correspondiente a la pantalla, sus tres miniaturas y el botón para añadir un escritorio. El helper de distribución leyó el escritorio activo y UUID válidos de dos de esos tres escritorios. Esta comprobación consistió en leer los controles. La creación y el arrastre físicos entre pantallas y la continuidad de las identidades tras reconectar quedan pendientes en el MacBook.
- ZIP de distribución [MacTop-0.1.1-universal.zip](../dist/MacTop-0.1.1-universal.zip). Se extrajo y se verificaron las firmas locales, las cuatro licencias y los ejecutables arm64 y x86_64, con mínimo de macOS 26.4 en ambos. SHA-256 `50bd63d72d9e98a5f951608a966b1458c0fa7deec2423b5494bd79e95e456dcd`.

### Evidencia local de 0.1.0 del 24 de noviembre de 2026

- En el Mac Studio con macOS 27.0.1 y SIP activo pasaron 40 pruebas, 16 del núcleo, 10 del adaptador y 14 del coordinador de la app.
- Una ventana AppKit de prueba creada para esta validación pasó del escritorio activo a otro escritorio nativo y volvió. El adaptador de MacTop verificó el mismo proceso, identificador de ventana, pantalla física y pertenencia exclusiva en ambos extremos. Se repitió con los objetos de la compilación de distribución y su componente empaquetado. Accesibilidad confirmó que el editor conservó el texto sin guardar antes y después del recorrido. La prueba utilizó un solo monitor.
- Se abrió la app empaquetada mediante LaunchServices y se comprobaron en su menú las dos acciones de guardado, la restauración manual, el automatismo y Accesibilidad. Se cerró la instancia de prueba al terminar.
- El ZIP extraído pasó la verificación de firma con `codesign --verify --deep --strict`. La app y el componente de Spaces incluyen arm64 y x86_64, con mínimo de macOS 26.4 en ambas arquitecturas. SHA-256 del ZIP entregado: `d3728a1503996338c05d905bcac80adbec8fb2bb6c1c341d52b4dba830241e3f`.
- El caso anterior falló en el MacBook a pesar de pasar estas comprobaciones en el Mac Studio. La [guía de prueba](../README.md) incluye la primera ida y vuelta y los diez ciclos de aceptación.

## 1. Comprobar el movimiento entre pantallas

- [ ] En el MacBook con macOS 26.6.2, identificar la ventana que ocupa cada uno de los tres escritorios numerados del externo e inventariar los Spaces de la pantalla integrada. Anotar qué conserva o cambia macOS al desconectar y al reconectar.
- [ ] Probar `spacectl` v2.2.2 con SIP activo. Trasladar una ventana identificable entre la integrada y la externa y recuperarla tras la reconexión. Repetir con una ventana representativa de cada modo utilizado.
- [ ] Contrastar pantalla y Space mediante una nueva lectura y Mission Control. Registrar si se conserva la ventana y su contenido. La autodetección del componente y su prueba entre dos escritorios de una sola pantalla son sólo comprobaciones preliminares.

**Resultado para continuar.** Mecanismo demostrado para las apps y los modos reales. Si faltan escritorios o hay que reconstruir el modo de una app, describir el caso y acordar el ajuste antes de construir sobre él.

## 2. Guardar los perfiles desde la barra de menús

Depende de 1. Afecta al menú, la captura y el archivo de perfiles.

- [ ] Capturar por separado «MacBook» y «MacBook + monitor». Identificar el monitor y conservar la secuencia de Spaces y sus ventanas por pantalla.
- [ ] Reiniciar la utilidad y recuperar los dos perfiles. Verificar que guardar uno sólo sustituye el elegido y que una escritura fallida conserva la copia válida.
- [x] Probar lectura y escritura local y correspondencia de pantallas con su orden de enumeración invertido. Verificado con archivos temporales reales e inventario simulado.

## 3. Restaurar por acción del usuario

Depende de 2. Afecta a la comparación de perfiles, al componente de Spaces y al resultado mostrado en el menú.

- [ ] Restaurar las ventanas de ambos perfiles y los modos demostrados en 1. Verificar la ventana, el monitor y la posición en Mission Control de cada destino. Preservar las ventanas ajenas al perfil.
- [x] Cubrir en pruebas una ventana ambigua, otra asignada a todos los escritorios, una app cerrada, un destino ausente y un fallo de movimiento. El coordinador conserva el perfil y muestra los diagnósticos.
- [x] Repetir la restauración sobre un perfil correcto. En la prueba del coordinador el contador de movimientos queda a cero y los perfiles guardados permanecen intactos.

**Antes de automatizar.** Completar al menos un recorrido manual de ida y vuelta con las ventanas reales. Incluir contenido de prueba sin guardar.

## 4. Activar el perfil al cambiar la configuración

Depende de 3. Afecta a los avisos de macOS y a la ejecución de la restauración.

- [x] Probar una ráfaga simulada de avisos. Sólo actúa la restauración correspondiente al estado final estable.
- [ ] Desconectar mientras hay un movimiento en curso. Esperar su resultado, volver a leer el estado y verificar que los movimientos pendientes del perfil anterior se descartan.
- [ ] Probar reposo y desbloqueo, monitor desconocido, falta de permisos y estado que no llega a estabilizarse. Comprobar que la app espera o explica el resultado y que los perfiles se conservan.

## 5. Aceptar el MVP en el MacBook

Depende de 4. Afecta a la validación y su registro.

- [ ] Ejecutar la compilación y las pruebas del proyecto. Anotar la versión de MacTop, macOS, el monitor y las apps usados en la prueba física.
- [ ] Hacer diez ciclos completos. Por cada extremo, registrar destinos esperados y observados, orden, modo, continuidad de las ventanas y cualquier intervención manual. Incluir reposo y reconexión rápida.
- [ ] Confirmar veinte distribuciones correctas, cero cierres o relanzados y cero correcciones manuales. Un fallo se documenta con su secuencia y se reproduce tras corregirlo. La versión final debe superar la serie completa.

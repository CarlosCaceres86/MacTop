# MacTop · Plan del MVP

**Objetivo.** Al enchufar o desenchufar su monitor habitual, el usuario recupera los escritorios del MacBook y las mismas ventanas abiertas en el orden que guardó para esa configuración. La primera versión se validará en su MacBook con **macOS 26.6.2**, la pantalla integrada y un monitor externo en modo extendido. El usuario confirma que en el externo hay tres escritorios numerados. El objetivo allí es devolver cada ventana al primero, segundo o tercero de ese monitor, según la secuencia guardada.

## Punto de partida

El proyecto empieza sin código. Hoy macOS mantiene los Spaces de cada pantalla y decide dónde quedan las ventanas cuando cambia la configuración. Las apps conservan el contenido de sus ventanas. MacTop guardaría únicamente la distribución deseada y consultaría la distribución real antes y después de actuar. Apple documenta tanto los avisos de cambio de pantallas como la diferencia entre un escritorio ordinario y el Space propio de una app a pantalla completa. [Cambios de pantallas](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification) · [Spaces de macOS](https://support.apple.com/es-es/guide/mac-help/mh14112/mac)

## Primera decisión técnica

Recomiendo una utilidad local de barra de menús en Swift y AppKit. Para la primera prueba usaría directamente `spacectl` de SpacePigeon **v2.2.2**. Se compila como ejecutable independiente, enumera ventanas y Spaces y comprueba si una ventana ha llegado al destino. Su autor documenta el movimiento con SIP activo desde macOS 26.4. La compatibilidad efectiva con 26.6.2 y con las apps del usuario se medirá en el portátil. Si se incorpora el código, se fijará la revisión y se conservarán la licencia MIT y las atribuciones originales. [Componente](https://github.com/louivers/spacepigeon/blob/v2.2.2/helper/spacectl.m) · [Compilación](https://github.com/louivers/spacepigeon/blob/v2.2.2/scripts/build_helper.sh) · [Licencia](https://github.com/louivers/spacepigeon/blob/v2.2.2/LICENSE)

Reutilizar el flujo completo de SpacePigeon ahorraría trabajo de interfaz, pero su editor vuelve a habilitar el relanzado de una app si falla el movimiento. Automatizar Mission Control mediante Accesibilidad permite reordenar Spaces de pantalla completa, a cambio de transiciones visibles y dependencia de la interfaz de macOS. Reservaría esta segunda vía para operaciones que el portátil demuestre necesarias. La propuesta mantiene SIP activo y pide Accesibilidad cuando la operación lo requiere. [Configuración de relanzado](https://github.com/louivers/spacepigeon/blob/v2.2.2/swift/ConfigUI.swift#L573-L580) · [Reordenación en Mission Control](https://github.com/louivers/spacepigeon/blob/v2.2.2/lua/mcdrag.lua)

## Qué guarda la app y cómo restaura

- **Dos perfiles explícitos.** El usuario organiza su sesión una vez con cada configuración y elige «Guardar esta distribución». Cada perfil queda en un archivo local, escrito de forma atómica. Sólo esta acción sustituye una distribución guardada. Una desconexión, un reposo o una restauración parcial nunca se convierten en la nueva referencia.
- **Pantalla y escritorio.** El destino identifica la pantalla integrada o el monitor externo reconocido, y la posición y el tipo del Space en la secuencia de Mission Control de esa pantalla. Al aplicar el perfil se resuelven los identificadores actuales. Cambiar la pantalla principal no debe invertir los destinos.
- **Misma ventana.** Durante la sesión, se comprueban la instancia de la app y la identidad de la ventana. Después de un reinicio de proceso, sólo se puede asociar una ventana nueva cuando hay una única candidata para la única entrada pendiente de esa app. Dos ventanas indistinguibles, una app cerrada o una ventana en todos los escritorios quedan pendientes con el motivo. La app conserva el trabajo abierto y sólo actúa sobre ventanas identificadas del perfil.
- **Resultado observable.** Con la configuración estable, la app compara el perfil con el estado actual, mueve sólo lo necesario y vuelve a leer pantalla, posición física y pertenencia al Space. Una ventana ordinaria cuenta como restaurada cuando pertenece exclusivamente al escritorio previsto de la pantalla prevista. Si ya estaba allí, no se mueve. El menú muestra el resultado y permite reintentar.

## Entregas y decisiones

| Entrega | Qué se demuestra |
| --- | --- |
| 1. Prueba de viabilidad en el MacBook | Registrar el tipo y orden de los Spaces en las dos configuraciones, las apps reales, el estado de «Pantallas con Spaces separados» y de la reordenación por uso. Observar qué conserva macOS en un ciclo. Con una ventana de prueba, y después con ventanas representativas, mover entre pantallas y devolverlas al destino tras reconectar. Verificar con una lectura posterior y en Mission Control. |
| 2. Captura de los dos perfiles | Guardar la distribución de cada configuración desde el menú, reiniciar MacTop y recuperar ambas. La captura conserva también los escritorios vacíos relevantes para el orden. |
| 3. Restauración manual | Recuperar ambos perfiles mediante «Restaurar ahora». Probar primero un destino correcto, después uno incorrecto y finalmente una ventana ambigua. Una segunda aplicación del perfil correcto debe producir cero movimientos. |
| 4. Restauración al cambiar de pantalla | Enchufar o desenchufar activa la misma restauración manual después de obtener lecturas coherentes de pantallas y Spaces, con un límite de espera. Al despertar o desbloquear se vuelve a comprobar si cambió la configuración o quedó una restauración pendiente. Ejecutar un solo movimiento cada vez. Si cambia la configuración durante uno, observar cómo termina, descartar los pasos pendientes y recalcular. |
| 5. Aceptación física | Completar diez ciclos de desconexión y reconexión en 26.6.2. Verificar los dos extremos de cada ciclo, incluido al menos uno tras reposo. Conservar el resultado observado de cada ciclo y los fallos por separado. |

### Decisión tras la prueba de reconexión

En el MacBook, al desconectar, macOS trasladó los tres escritorios del externo a la pantalla integrada. Al reconectar apareció un único escritorio en el externo. El usuario eligió devolver cada escritorio original identificable con todas sus ventanas, incluidas las que abrió después de guardar el perfil.

En 0.1.1 la restauración manual y la automática comparten el mismo orden. MacTop localiza los originales, los devuelve a sus posiciones mediante Mission Control, crea los destinos que aún falten y finalmente comprueba las ventanas guardadas. Tras cada gesto vuelve a leer ambas pantallas. Una devolución que no puede verificar detiene esa restauración. Un perfil de 0.1.0 conserva el número de destinos, pero sólo una nueva captura explícita documenta la identidad de los originales que ya están presentes.

Si el externo recibe un escritorio nuevo de macOS y sobreviven los tres originales, se conservan los cuatro. Los tres del perfil quedan primero, en su orden, y el menú informa del adicional. Esta decisión protege las ventanas abiertas en el escritorio nuevo. La aceptación debe distinguir este caso del caso en que el escritorio que ya muestra el externo es uno de los tres originales.

### Una sesión de Mission Control por reconexión

El usuario observó que 0.1.2 era más rápida y pidió mover sus tres escritorios en una sola apertura. En 0.1.3 la recuperación de escritorios comparte Mission Control desde el primer gesto hasta que termina. La app distingue si abrió la vista o si ya estaba abierta y respeta ese estado al finalizar. Cada arrastre sigue consultando las miniaturas actuales y verificando el escritorio, el monitor y el orden de llegada. Las tres lecturas de estabilidad se mantienen porque ya funcionaron en el MacBook.

Si un escritorio que se va a trasladar está activo, MacTop activa otro escritorio de esa pantalla. El usuario aceptó que la app reabra Mission Control si salió de la vista al realizar ese cambio y puede confirmarlo. Si la vista desaparece entre dos gestos ordinarios, el lote se interrumpe y el usuario decide cuándo reintentar.

Los tres escritorios numerados del externo permiten empezar moviendo ventanas ordinarias a destinos existentes. Queda por inventariar la pantalla integrada. Sólo si allí aparece una app a pantalla completa o una pareja de Split View que forme parte de la distribución solicitada se probará la recuperación de su modo y posición. Ese resultado serviría para acordar una ampliación antes de implementarla.

## Criterio de aceptación

**Diez ciclos y veinte distribuciones correctas** en el MacBook objetivo. En cada extremo deben coincidir el orden guardado, las tres apps del externo cuando corresponda y las ventanas del portátil. Las mismas ventanas de la sesión conservan su contenido, incluido un cambio de prueba sin guardar. Ninguna app se cierra o relanza. Las pruebas de interrupción y ambigüedad se registran aparte y deben dejar el trabajo accesible y explicar cualquier resultado parcial.

El Mac Studio disponible sirve para compilar y ejecutar pruebas de lógica. La aceptación física depende del MacBook, su monitor y sus aplicaciones. La compatibilidad obtenida tiene como referencia macOS 26.6.2. Un cambio de macOS exige repetir la prueba de movimiento antes de dar por compatible otra versión.

Las tareas y sus comprobaciones están en [la lista de implementación](todo.md).

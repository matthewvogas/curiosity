# Curiosity

Un simulador de robots con IA para macOS. Cargas cualquier robot (URDF o MJCF), conectas un modelo de IA y le
pides tareas en tus palabras: la IA mira la escena, planea y mueve el robot en una simulación con física.

- **Simulación con MuJoCo** (el binding oficial de Google DeepMind, `@mujoco/mujoco` 3.15, en WebAssembly):
  un MJCF se carga tal cual (actuadores, tendones, igualdades, contactos); un URDF se convierte a MJCF con
  sus masas, inercias, límites, motores de posición (kp, kv, fuerza máxima), <mimic> como igualdades y las
  mallas cóncavas partidas en piezas convexas. Contactos, sensores (posición, velocidad, fuerza, contactos),
  cámaras montadas, objetos libres, pausa, paso a paso y velocidad. three.js dibuja.
- **IA**: Claude con herramientas (`get_state`, `move_joints`, `look`, `add_object`, `remove_object`,
  `reset`). La API key se guarda en el Llavero. Las conversaciones se guardan por robot (Historial, en el chat).
- **Robots reales** (por ahora el SO-101), con tu instalación de LeRobot (la app la busca sola; si no, se
  indica en Ajustes). Cada robot conectado es como un proyecto:
  - **Enseñar**: tareas en tres pasos (grabar demostraciones con el leader, entrenar ACT / Diffusion /
    SmolVLA, probar el modelo), con revisión previa de cada pieza antes de mover nada.
  - **En vivo**: las cámaras y un gemelo 3D que copia la pose del robot; chat con la IA (cada movimiento se
    aprueba) y control manual; «Saber»: la IA estudia demostraciones (de esta Mac o de Hugging Face) y las
    reproduce y adapta en el robot sin entrenar.
  Lo hace un puente interno (`resources/bridge/curiosity_bridge.py`) que corre con el Python de LeRobot y
  habla con la app por líneas JSON. Los entrenamientos corren aparte con `lerobot-train` y siguen aunque se
  cierre la app. Datos y modelos en Application Support/Curiosity. Calibrar se hace en la terminal.
- **Robots**: el SO-101 viene incluido; cualquier URDF o MJCF se importa con sus mallas STL, OBJ o DAE; y la
  **biblioteca** trae 67 robots de MuJoCo Menagerie (brazos, pinzas, manos, cuadrúpedos, humanoides, móviles,
  drones) que se descargan con un clic en una versión fija del repositorio y quedan en la Mac.
- **Pinzas que agarran**: articulaciones acopladas (`<mimic>` en URDF; `<equality joint>` y tendones fijos en
  MJCF) y descomposición convexa de las mallas cóncavas (`decompose.js`).

## Correr

    brew install xcodegen   # una vez
    xcodegen && open Curiosity.xcodeproj   # ⌘R

## Estructura

```
Curiosity/
  app/          entrada de la app (escenas, ventana)
  screens/      juntan stores y componentes; lo único que lee los stores
  components/   solo dibujan; todo les llega por props (incluido <Icon name: size:>)
  stores/       use-*.swift: orquestan queries y guardan carga, error y datos (los «hooks»)
  queries/      hablan con el disco, el Llavero, la API de Claude y el motor 3D; sin estado
  utils/        lógica pura: unidades, herramientas de la IA, tema
  types/        tipos de datos
  resources/
    studio/     motor de simulación, sin internet:
                  engine.js      escena, física (MuJoCo) y API para la app
                  mjcf-build.js  URDF → MJCF y la escena (piso y objetos)
                  model-urdf.js  URDF → modelo interno
                  model-mjcf.js  MJCF → modelo interno
                  decompose.js   descomposición convexa de mallas
                  lib/           three.js y MuJoCo (WebAssembly)
    library/    catálogo de MuJoCo Menagerie (menagerie.json)
    robots/     robots incluidos: <id>/<id>.urdf + <id>.studio.json + mallas
```

Reglas:

1. **Components** no llaman stores ni queries, ni contienen reglas de negocio: reciben datos y callbacks.
2. **Stores** no dibujan ni contienen reglas de negocio; pueden componer otros stores.
3. **Queries**: una por fuente de datos; devuelven lo crudo, sin estado.
4. **Utils**: validaciones, conversiones y cálculos; nada de lógica compleja en componentes.
5. **Nombres**: archivos y carpetas en kebab-case (`use-chat.swift`, `chat-view.swift`). Dentro de Swift,
   el estilo de Swift (`UseChat`, `sendMessage`), para que el compilador y Xcode sigan siendo idiomáticos.

## Perfil de un robot (`<nombre>.studio.json`, opcional, junto al URDF)

```json
{
  "name": "SO-101",
  "description": "…",
  "home": { "shoulder_lift": -1.74 },
  "actuators": { "shoulder_pan": { "kp": 30, "kd": 1.5, "fmax": 3 } },
  "cameras": [{ "name": "Muñeca", "link": "gripper_link", "pos": [0, 0, 0], "quat": [0, 0, 0, 1], "fovy": 60 }],
  "scene": { "objects": [{ "shape": "box", "size": [0.03, 0.03, 0.03], "mass": 0.02, "color": "#e4572e", "pos": [0.2, 0, 0.02] }] }
}
```

Unidades SI (metros, radianes, kg). Las cámaras miran hacia −z, como en MuJoCo.

## Pendiente

Del MJCF: `<equality weld/connect>` (mecanismos de cuatro barras, como la Robotiq 2F-85), tendones espaciales,
músculos, mallas definidas por vértices. Además: robots físicos (LeRobot), otros proveedores de IA y modelos
de robots (VLA), entrenamiento, simulación más rápida que el tiempo real y en lotes, sensores de fuerza reales
del actuador, aleatorización de dominio, grabar datasets.

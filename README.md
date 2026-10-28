# Curiosity

Un simulador de robots con IA para macOS. Cargas cualquier robot (URDF), conectas un modelo de IA y le
pides tareas en tus palabras: la IA mira la escena, planea y mueve el robot en una simulación con física.

- **Simulación** (lo esencial de MuJoCo, sobre Rapier): cuerpos con masa e inercia del URDF, articulaciones
  revolute / continuous / prismatic / fixed con límites, motores de posición PD con fuerza máxima,
  contactos con fricción y rebote, sensores (posición, velocidad, fuerza, contactos), cámaras montadas en
  el robot, objetos libres, pausa, paso a paso y velocidad.
- **IA**: Claude con herramientas (`get_state`, `move_joints`, `look`, `add_object`, `remove_object`,
  `reset`). La API key se guarda en el Llavero.
- **Robots**: el SO-101 viene incluido; cualquier URDF se importa con sus mallas STL, OBJ o DAE.

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
    studio/     motor de simulación (engine.js) y sus librerías (three.js, Rapier), sin internet
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

MJCF, robots físicos (LeRobot), biblioteca online, otros proveedores de IA y modelos de robots (VLA),
entrenamiento, simulación más rápida que el tiempo real y en lotes, descomposición convexa de mallas,
sensores de fuerza reales del actuador, aleatorización de dominio, grabar datasets.

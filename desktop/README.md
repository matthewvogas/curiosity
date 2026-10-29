# Curiosity (escritorio: macOS, Windows y Linux)

La misma app que `../Curiosity` (SwiftUI, solo macOS), hecha con **Tauri 2 + React + TypeScript + MobX**.
El motor 3D (`../Curiosity/resources/studio`), los robots incluidos, la biblioteca y el puente de LeRobot
(`../Curiosity/resources/bridge`) se comparten tal cual: Tauri los empaqueta desde ahí.

    npm install
    npx tauri dev          # desarrollo
    npx tauri build        # instalador (.dmg en macOS, .msi/.exe en Windows)

Los datos son los mismos que los de la versión de macOS (Application Support/Curiosity; en Windows
`%APPDATA%\Curiosity`), y las API keys van en el Llavero (Administrador de credenciales en Windows), con un servicio propio (`com.rosvelt.curiosity.desktop`): hay que guardarlas una vez en Ajustes.

## Estructura (las mismas capas y reglas que la versión de Swift)

```
src/
  app/          entrada: stores.tsx crea todos los stores una vez (useStores())
  screens/      juntan stores y componentes; lo único que lee los stores (observer + useStores)
  components/   solo dibujan; todo les llega por props. components/ui = el kit de diseño
  stores/       use-*.ts: clases MobX que orquestan queries y guardan carga, error y datos
  queries/      hablan con el disco, el almacén seguro, la API de Claude, el puente y el motor 3D; sin estado
  utils/        lógica pura (unidades, herramientas de la IA, nombres)
  types/        tipos de datos
  styles/       tokens.css (colores, tipografía, radios) y base.css
src-tauri/      la parte nativa en Rust (archivos, llavero, puerto serie, procesos, curiosity://)
```

Reglas:

1. **Components** no llaman stores ni queries, ni contienen reglas de negocio: reciben datos y callbacks.
2. **Stores** no dibujan ni contienen reglas de negocio; pueden componer otros stores.
3. **Queries**: una por fuente de datos; devuelven lo crudo, sin estado.
4. **Utils**: validaciones, conversiones y cálculos; nada de lógica compleja en componentes.
5. **Nombres**: archivos en kebab-case (`use-chat.ts`, `chat-view.tsx`, `chat-view.module.css`); dentro, el
   estilo de TypeScript (`UseChat`, `sendMessage`). Cada archivo de Swift tiene su par con el mismo nombre.

## Cómo se porta un archivo de Swift

- `@Observable final class UseX` → `export class UseX { constructor(...) { makeAutoObservable(this) } }`.
  `private(set) var` → propiedad pública que solo cambia el propio store. Lo async: `await` y después
  `runInAction(() => …)` (o directo: `enforceActions` está apagado). `UserDefaults` → `Preferences`.
- Vistas de SwiftUI → componentes de función. Pantallas con `observer(...)` y `useStores()`. Componentes sin
  MobX: props planas (valores y callbacks).
- `Task { … }` / `.task` → `useEffect` en la pantalla que llama al store. Timers → `setInterval` con limpieza.
- Fechas: los tipos guardan `SwiftDate` (segundos desde 2001) para leer los archivos de la versión de macOS;
  `swiftDate.now()`, `swiftDate.toDate(d)`. UUID: `uuid()` (mayúsculas). Data: base64 (`utils/codable.ts`).
- Imágenes (JPEG de cámaras y capturas) viajan como base64 sin prefijo; para mostrarlas, `jpegDataURL(b64)`.
- Textos de la interfaz en inglés (como la versión actual), comentarios en español.

## Diseño

Oscuro y neutro, de herramienta de trabajo (en la línea de Conductor, Cursor o Grok): grafito casi negro,
bordes de 1 px, texto claro, un solo acento y color solo para estados.

- Tokens en `styles/tokens.css`: `--bg`, `--sidebar`, `--surface`, `--raised`, `--overlay`, `--stage`; `--line`;
  `--hover`, `--selected`, `--fill`; `--ink`, `--muted`, `--faint`; `--green`, `--amber`, `--red`, `--blue`
  (con `-soft`); `--text-xs…xxl`; `--s-1…6`; `--r-xs…xl`; `--mono`. Nunca colores sueltos en los componentes.
- Kit en `components/ui` (importar de `@/components/ui`): `Button` (primary · secondary · ghost · danger ·
  success), `IconButton`, `Tabs` (pill · underline), `Field`, `TextInput`, `TextArea`, `Select`, `Switch`,
  `SwitchRow`, `Slider`, `Section`, `Card`, `Divider`, `Badge`, `StatusDot`, `Kbd`, `Spinner`, `Progress`,
  `Callout`, `EmptyState`, `Dialog`, `Menu`/`useMenu`, `Icon` (nombres en `ui/icon.tsx`; agregar ahí los que
  falten), `Logo`, `cx`.
- Marco: `components/app-shell.tsx`. Cada pantalla devuelve
  `<Workspace inspector={<Pane inspector …/>}><Pane title actions>…</Pane></Workspace>`. El encabezado de un
  `Pane` es la barra de título (se arrastra la ventana desde ahí). El panel principal va al centro y el
  inspector (chat, control, escena…: lo que en macOS era el panel flotante) a la derecha, de 400 px.
- Estilos con CSS Modules junto al componente. Separar con bordes, no sombras; la sombra solo en lo que flota.
- Chat al estilo Grok/Conductor: lo de la persona en un globo a la derecha (`--raised`, radio 18), lo de la IA
  como texto plano a todo el ancho, las acciones como filas compactas plegables, y el compositor abajo en una
  caja redondeada con el modelo y el botón de enviar (círculo claro con flecha).
- Números (articulaciones, tiempos, fuerzas): `font-variant-numeric: tabular-nums` o `--mono`.

## Plataforma

- `queries/native.ts`: `nativePaths()`, `isWindows()`, `isMac()`, `join()`, `Files.*` (leer, escribir, listar,
  borrar, tail) y `on(evento)`. Las rutas siempre con `join`, nunca con "/".
- El visor 3D es un iframe de `curiosity://localhost/app/studio/index.html` (Windows:
  `http://curiosity.localhost/…`); `SimulationQueries` le habla por postMessage (`studio/rpc.js`).
- Puertos serie: `DeviceQueries.connectedPorts()` (macOS `/dev/cu.usb…`, Windows `COM3`…).
- Entrenamiento: en macOS `--policy.device=mps`; en Windows y Linux decide LeRobot (CUDA o CPU).

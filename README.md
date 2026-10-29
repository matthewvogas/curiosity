# Curiosity

A desktop app for people who want to teach a robot something without living in a terminal.

I got an SO-101 arm and spent four days on ports, motor IDs, calibration, cameras and training commands before I could even test a task. Curiosity is what I wished I had on day one. You open it and there are two buttons: open a simulator, or connect your robot.

There's a longer story on my blog: [Robots Don't Have a Cursor Yet](https://matthewvogas.com/blog/r-ui).

## What it does

**Simulator.** Load a robot and move it in a physics simulation. The SO-101 comes included. You can import any URDF or MJCF, or download one of 67 robots from MuJoCo Menagerie with one click: arms, grippers, hands, quadrupeds, humanoids. You can also talk to Claude and ask it to move the robot. It sees the scene and uses tools to do it.

**Real robot.** Plug in an SO-101. Curiosity checks that the six motors answer, that the arm is calibrated and that the cameras give an image. Then you see it live: the cameras, a 3D copy that follows the real arm, and the same chat. The arm only moves with the controls, or when you approve what the AI proposes.

**Teach.** Describe a task in one sentence. Record a few demonstrations with the leader arm, train (ACT, Diffusion or SmolVLA), and test it on the robot. Or skip recording and train on demonstrations other people uploaded to Hugging Face for the same robot.

Nothing in here is new science. It runs on the same open source tools you'd use from the terminal: MuJoCo for physics and LeRobot for recording and training.

## Two versions

There are two apps in this repo. They do the same thing and read the same files, so you can switch between them.

| | Folder | Built with | Runs on |
|---|---|---|---|
| Mac | `Curiosity/` | SwiftUI | macOS 26+ |
| Desktop | `desktop/` | Tauri 2, React, TypeScript | macOS, Windows, Linux |

The simulator engine, the included robots, the robot library and the LeRobot bridge live in `Curiosity/resources/` and both apps use them as they are.

### Mac

```sh
brew install xcodegen
xcodegen
open Curiosity.xcodeproj
```

Then ⌘R in Xcode.

### Desktop

```sh
cd desktop
npm install
npx tauri dev      # development
npx tauri build    # installer (.dmg, .msi, .exe)
```

You'll need Node 22 and Rust. There's a GitHub Action in `.github/workflows/desktop.yml` that builds the Windows and macOS installers, so you don't need a Windows machine.

### What you need for the rest

- An [Anthropic API key](https://console.anthropic.com) for the chat. It's stored in the system keychain.
- For a real robot: an SO-101 and a working [LeRobot](https://github.com/huggingface/lerobot) install. Curiosity looks for it on its own; if it can't find it, you can point to it in Settings. Calibration still happens in the terminal for now.

## How the code is organized

Both apps follow the same layers, and every Swift file has a TypeScript twin with the same name.

```
app/          entry point
screens/      connect stores to components; the only place that reads stores
components/   only draw; everything comes in as props
stores/       use-*: load data, keep loading/error state
queries/      talk to the disk, the keychain, the Claude API, the bridge and the 3D engine; no state
utils/        pure logic: units, AI tools, naming
types/        data types
```

The robot bridge (`Curiosity/resources/bridge/curiosity_bridge.py`) runs with LeRobot's Python and talks to the app over JSON lines. Training runs separately with `lerobot-train`, so it keeps going if you close the app.

`desktop/README.md` has more detail on the desktop version, written in Spanish.

## What's missing

- Four-bar mechanisms in MJCF (`<equality weld/connect>`), so grippers like the Robotiq 2F-85 don't close properly yet
- Spatial tendons, muscles
- Robots other than the SO-101 on the real side
- Calibration inside the app
- Faster-than-real-time and batched simulation

It's a start. The robot still can't finish my Jenga row.

## Credits

Made by Matthew Vogas, with [Cursor](https://cursor.com) and [Claude](https://claude.ai) as co-creators. A lot of this code was written in conversation with them.

Built on:

- [MuJoCo](https://github.com/google-deepmind/mujoco) 3.15 by Google DeepMind (Apache 2.0), bundled as WebAssembly
- [three.js](https://github.com/mrdoob/three.js) (MIT)
- [SO-101](https://github.com/TheRobotStudio/SO-ARM100) model by TheRobotStudio and Hugging Face (Apache 2.0)
- [MuJoCo Menagerie](https://github.com/google-deepmind/mujoco_menagerie), downloaded on demand; each robot keeps its own license
- [LeRobot](https://github.com/huggingface/lerobot) by Hugging Face (Apache 2.0), installed separately

## License

MIT. See [LICENSE](LICENSE). The bundled third-party files keep their own licenses.

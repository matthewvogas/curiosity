"""Puente entre la app Curiosity y LeRobot.

La app lo corre con el Python donde está instalado LeRobot y le habla por líneas JSON:
  entrada (stdin):  {"id": 1, "cmd": "teleop", ...}       una orden por línea
  salida (stdout):  {"id": 1, "ok": true, ...}             la respuesta a esa orden
                    {"event": "record", ...}               avisos mientras corre algo

Hace lo mismo que los comandos de LeRobot, con su mismo código:
  lerobot-teleoperate   → cmd "teleop"
  lerobot-record        → cmd "record" (demostraciones con el leader)
  lerobot-rollout       → cmd "rollout" (el robot usa un modelo entrenado)
y además: calibraciones guardadas, una foto de prueba, la revisión previa, el estudio de datasets y los locales.
Una sola sesión con el robot a la vez. Nada se mueve sin una orden de la app, que antes pide
confirmación a la persona.
"""

import base64
import functools
import json
import shutil
import sys
import threading
import time
from pathlib import Path

_out_lock = threading.Lock()


def emit(obj: dict) -> None:
    with _out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def clean(e: Exception) -> str:
    return " ".join(str(e).split()) or type(e).__name__


CALIBRATION_ROOT = Path.home() / ".cache" / "huggingface" / "lerobot" / "calibration"


# ---------------------------------------------------------------------------------------------
# Cualquier robot de LeRobot: el tipo elige la clase; las articulaciones y sus unidades salen del robot
# ---------------------------------------------------------------------------------------------
@functools.cache
def registries():
    """Los registros de robots y teleoperadores de LeRobot, con todos sus módulos cargados (cada uno se registra
    al importarse). Uno que no carga, por una dependencia que falta, simplemente no aparece."""
    import importlib
    import pkgutil
    import lerobot.robots as robots
    import lerobot.teleoperators as teleoperators
    from lerobot.robots.config import RobotConfig
    from lerobot.teleoperators.config import TeleoperatorConfig

    for pkg in (robots, teleoperators):
        for module in pkgutil.iter_modules(pkg.__path__):
            try:
                importlib.import_module(f"{pkg.__name__}.{module.name}")
            except Exception:
                pass
    return RobotConfig, TeleoperatorConfig


def robot_type(msg: dict) -> str:
    if not msg.get("robot_type"):
        raise ValueError("Choose the robot type in Robot settings.")
    return msg["robot_type"]


def teleop_type(msg: dict) -> str:
    if not msg.get("teleop_type"):
        raise ValueError("Choose the leader type in Robot settings.")
    return msg["teleop_type"]


def build_config(base, type_: str, **values):
    """La configuración de LeRobot de ese tipo, con los valores que ese tipo acepta (no todos tienen puerto,
    cámaras o use_degrees)."""
    cls = base.get_choice_class(type_)
    fields = cls.__dataclass_fields__
    return cls(**{k: v for k, v in values.items() if k in fields and v is not None})


def accepts(base, type_: str, field: str) -> bool:
    return field in base.get_choice_class(type_).__dataclass_fields__


def release(device) -> None:
    """Suelta motores y cámaras de un robot aunque algo falle a mitad (no terminó de conectar, el bus de motores
    tira error al cerrar…): cada cámara se cierra por separado, porque una que queda abierta sigue tomada y otras
    apps (o la próxima sesión) no la pueden usar."""
    if device is None:
        return
    try:
        if device.is_connected:
            device.disconnect()
    except Exception:
        pass
    for cam in list(getattr(device, "cameras", {}).values()):
        try:
            if cam.is_connected:
                cam.disconnect()
        except Exception:
            pass


def make_robot(msg: dict, **values):
    from lerobot.robots import make_robot_from_config

    RobotConfig, _ = registries()
    # Sin puerto también se puede crear (para leer su calibración sin conectarlo).
    return make_robot_from_config(build_config(RobotConfig, robot_type(msg), port=msg.get("follower_port") or "",
                                               id=msg.get("follower_id"), **values))


def make_leader(msg: dict, **values):
    from lerobot.teleoperators import make_teleoperator_from_config

    _, TeleoperatorConfig = registries()
    return make_teleoperator_from_config(build_config(TeleoperatorConfig, teleop_type(msg), port=msg.get("leader_port") or "",
                                                      id=msg.get("leader_id"), **values))


UNITS = {"degrees": "deg", "range_0_100": "0-100", "range_m100_100": "±100"}


def joint_units(device) -> dict:
    """Las articulaciones de posición del robot o leader, en orden, con su unidad: «deg», «0-100» o «±100».
    Salen de LeRobot (action_features y el modo de cada motor), no de una lista fija."""
    bus = getattr(device, "bus", None)
    out = {}
    for key in device.action_features:
        if key.endswith(".pos"):
            name = key.removesuffix(".pos")
            mode = bus.motors[name].norm_mode.value if bus is not None and name in bus.motors else "range_m100_100"
            out[name] = UNITS.get(mode, "±100")
    return out


def half_span_degrees(device, name: str) -> float | None:
    """Medio recorrido calibrado de una articulación, en grados (con la resolución de su motor)."""
    bus, cal = getattr(device, "bus", None), getattr(device, "calibration", {}).get(name)
    if bus is None or cal is None or name not in bus.motors:
        return None
    return (cal.range_max - cal.range_min) / 2 * 360 / (bus.resolution(bus.motors[name].model) - 1)


def is_gripper(name: str) -> bool:
    return "gripper" in name or "hand" in name


# ---------------------------------------------------------------------------------------------
# Consultas
# ---------------------------------------------------------------------------------------------
def cmd_hello(_: dict) -> dict:
    import lerobot

    user = None
    try:
        from huggingface_hub import whoami

        user = whoami()["name"]
    except Exception:
        pass
    import importlib.util

    return {"lerobot": getattr(lerobot, "__version__", "?"), "hf_user": user,
            "smolvla": importlib.util.find_spec("transformers") is not None, "python": sys.executable}


def cmd_calibrations(_: dict) -> dict:
    """IDs con calibración guardada: {"robots": {"so_follower": ["mi_follower"]}, "teleoperators": {...}}."""
    out = {}
    for kind in ("robots", "teleoperators"):
        out[kind] = {}
        for d in sorted((CALIBRATION_ROOT / kind).glob("*")):
            ids = sorted(p.stem for p in d.glob("*.json"))
            if ids:
                out[kind][d.name] = ids
    return out


def cmd_robot_types(_: dict) -> dict:
    """Los robots y teleoperadores que trae LeRobot, con la carpeta donde guardan su calibración."""
    from lerobot.robots import make_robot_from_config
    from lerobot.teleoperators import make_teleoperator_from_config

    RobotConfig, TeleoperatorConfig = registries()

    def describe(base, make):
        out = []
        for name in sorted(base.get_known_choices()):
            entry = {"type": name, "port": accepts(base, name, "port"), "calibration": None}
            try:
                entry["calibration"] = make(build_config(base, name, port="", id="_")).calibration_fpath.parent.name
            except Exception:
                pass  # uno que no se puede crear sin conectarse: se puede elegir igual
            out.append(entry)
        return out

    return {"robots": describe(RobotConfig, make_robot_from_config),
            "teleoperators": describe(TeleoperatorConfig, make_teleoperator_from_config)}


def cmd_snapshot(msg: dict) -> dict:
    """Una foto de la cámara `index` (JPEG en base64), para elegir la correcta."""
    import cv2

    cap = cv2.VideoCapture(int(msg["index"]))
    try:
        frame = None
        for _ in range(8):  # los primeros cuadros suelen salir oscuros
            ok, frame = cap.read()
        if frame is None:
            raise ValueError("The camera didn't send an image (is another app using it?).")
        frame = cv2.resize(frame, (480, int(480 * frame.shape[0] / frame.shape[1])))
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
        return {"jpeg": base64.b64encode(buf.tobytes()).decode()}
    finally:
        cap.release()


def cmd_preflight(msg: dict) -> dict:
    """Revisa cada pieza antes de grabar o probar, sin mover nada (solo lee los motores):
    follower, leader, que estén en poses parecidas y la cámara. Devuelve una lista de revisiones
    {key, state: ok · warn · fail, detail}."""
    checks, poses = [], {}

    def arm(key, make):
        try:
            obj = make()
        except Exception as e:
            checks.append({"key": key, "state": "fail", "detail": clean(e)})
            return
        bus = getattr(obj, "bus", None)
        if bus is None:
            checks.append({"key": key, "state": "warn", "detail": "Can't check this type without connecting."})
            return
        try:
            bus.connect()
            if not bus.is_calibrated:
                checks.append({"key": key, "state": "fail", "detail": "The saved calibration doesn't match the motors. Calibrate again in the terminal."})
                return
            poses[key] = bus.sync_read("Present_Position")
            checks.append({"key": key, "state": "ok", "detail": f"All {len(bus.motors)} motors respond and it's calibrated."})
        except Exception as e:
            text = clean(e)
            if "busy" in text.lower() or "resource" in text.lower():
                detail = "The port is busy: close other apps using the robot."
            elif "missing" in text.lower() or "found" in text.lower() or "No such file" in text:
                detail = "Not responding. Check the USB cable and that the power supply is on."
            else:
                detail = text
            checks.append({"key": key, "state": "fail", "detail": detail})
        finally:
            try:
                bus.disconnect(disable_torque=False)
            except Exception:
                pass

    arm("follower", lambda: make_robot(msg))
    if msg.get("leader_port"):
        arm("leader", lambda: make_leader(msg))
        if "follower" in poses and "leader" in poses:
            # Las dos lecturas vienen normalizadas igual (±100 o 0–100), así que se comparan en esa escala.
            shared = [j for j in poses["follower"] if j in poses["leader"] and not is_gripper(j)]
            diff = max((abs(poses["follower"][j] - poses["leader"][j]) for j in shared), default=0)
            if diff > 25:
                checks.append({"key": "pose", "state": "warn", "detail": "They're in different poses. Bring the leader closer."})
            else:
                checks.append({"key": "pose", "state": "ok", "detail": "Close enough."})

    cam = msg.get("camera")  # moverlo con el leader no usa cámara
    if cam is not None:
        try:
            from lerobot.cameras.opencv import OpenCVCamera

            config = camera_config(cam["index"])
            c = OpenCVCamera(config)
            c.connect()
            try:
                c.read()
            finally:
                c.disconnect()
            checks.append({"key": "camera", "state": "ok", "detail": f"Sending images at {config.width}×{config.height}, {config.fps} fps."})
        except Exception as e:
            text = clean(e)
            if "open" in text.lower() or "authoriz" in text.lower():
                detail = "Couldn't open it: check Curiosity's camera permission and make sure no other app is using it."
            else:
                detail = text
            checks.append({"key": "camera", "state": "fail", "detail": detail})

    for i, index in enumerate(msg.get("extra_cameras") or [], start=1):
        try:
            from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig

            # La misma configuración que usará el modelo (camera_config), para que lo que pase aquí pase allá.
            c = OpenCVCamera(camera_config(index))
            c.connect()
            try:
                frame = c.read()
            finally:
                c.disconnect()
            checks.append({"key": f"cam{i}", "state": "ok", "detail": f"Sending images ({frame.shape[1]}×{frame.shape[0]})."})
        except Exception as e:
            checks.append({"key": f"cam{i}", "state": "fail",
                           "detail": f"Didn't respond ({clean(e)})."})
    return {"checks": checks}


def cmd_study(msg: dict) -> dict:
    """Lo que la IA necesita para estudiar un dataset de LeRobot (local o del Hub, se baja solo lo usado):
    tareas, trayectorias de unas demostraciones (en grados con la calibración de este robot), cuándo cierra
    y abre la pinza, y fotos de esos momentos. Para la IA y para reproducir tramos en vivo; no entrena nada."""
    import numpy as np
    import cv2
    from lerobot.datasets.lerobot_dataset import LeRobotDataset, LeRobotDatasetMetadata

    repo_id, root = msg["repo_id"], msg.get("root")
    meta = LeRobotDatasetMetadata(repo_id, root=root)
    total = meta.total_episodes
    count = min(int(msg.get("episodes", 6)), total)
    picks = sorted({round(i * (total - 1) / max(1, count - 1)) for i in range(count)}) if total else []
    ds = LeRobotDataset(repo_id, root=root, episodes=picks)
    names = [n.removesuffix(".pos") for n in (meta.features.get("observation.state", {}).get("names") or [])]
    if not names:
        raise ValueError("This dataset has no joint names.")
    # Solo sirve con las articulaciones de este robot (con su nombre): así se puede reproducir en vivo.
    mine = joint_units(make_robot(msg)) if msg.get("follower_id") else {n: "±100" for n in names}
    joints = [j for j in mine if j in names]
    if not joints:
        raise ValueError(f"This dataset's joints ({', '.join(names)}) aren't this robot's ({', '.join(mine)}).")
    order = [names.index(j) for j in joints]
    grip = next((i for i, j in enumerate(joints) if is_gripper(j)), None)
    video_keys = list(meta.video_keys)

    states = np.asarray(ds.hf_dataset["observation.state"], dtype=float)[:, order]
    episodes_col = np.asarray(ds.hf_dataset["episode_index"])
    times = np.asarray(ds.hf_dataset["timestamp"], dtype=float)
    body = states[:, [i for i in range(len(joints)) if i != grip]] if len(joints) > 1 else states
    degrees = np.abs(body).max() > 110  # con use_degrees los valores pasan de ±100; si no, van de -100 a 100
    half = half_spans(msg)
    # Lo que va de -100 a 100 y tiene calibración se pasa a grados (como en vivo); lo demás queda en su escala.
    shown = {j: "deg" if degrees or (mine.get(j) == "±100" and half.get(j)) else mine.get(j, "±100") for j in joints}
    to_deg = (lambda row: row) if degrees else (
        lambda row: [v / 100 * half[j] if shown[j] == "deg" else v for j, v in zip(joints, row)])

    tasks = {int(i): str(t) for t, i in zip(meta.tasks.index, meta.tasks["task_index"])} if hasattr(meta.tasks, "index") else {}
    out_eps, keyframes = [], []
    for e in picks:
        rows = np.nonzero(episodes_col == e)[0]
        if len(rows) == 0:
            continue
        t0 = times[rows[0]]
        step = max(1, int(round(meta.fps / 10)))  # 10 por segundo alcanza para reproducir
        traj = [[round(float(times[r] - t0), 2)] + [round(float(v), 1) for v in to_deg(states[r])] for r in rows[::step]]
        if grip is None:
            out_eps.append({"episode": int(e), "duration_s": round(float(times[rows[-1]] - t0), 1), "trajectory": traj,
                            "gripper_events": []})
            continue
        grip_values = states[rows, grip]
        events, closing = [], None
        smooth = np.convolve(grip_values, np.ones(5) / 5, mode="same")
        diff = np.diff(smooth)
        for k in range(1, len(diff)):
            sign = -1 if diff[k] < -0.4 else (1 if diff[k] > 0.4 else 0)
            if sign and sign != closing:
                events.append({"t": round(float(times[rows[k]] - t0), 2), "gripper": "closes" if sign < 0 else "opens",
                               "row": int(rows[k])})
                closing = sign
        task_index = int(np.asarray(ds.hf_dataset["task_index"])[rows[0]]) if "task_index" in ds.hf_dataset.column_names else 0
        out_eps.append({"episode": int(e), "task": tasks.get(task_index, ""), "duration_s": round(float(times[rows[-1]] - t0), 1),
                        "trajectory": traj, "gripper_events": [{k: v for k, v in ev.items() if k != "row"} for ev in events]})
        if len(keyframes) < 12 and video_keys:
            moments = [("start", int(rows[0]))] + [(f"gripper {ev['gripper']} ({ev['t']} s)", ev["row"]) for ev in events[:3]] + [("end", int(rows[-1]))]
            for label, r in moments:
                try:
                    img = ds[int(r)][video_keys[0]]  # r es la posición dentro de lo cargado
                    rgb = (img.permute(1, 2, 0).numpy() * 255).astype("uint8") if hasattr(img, "permute") else np.asarray(img)
                    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
                    bgr = cv2.resize(bgr, (384, int(384 * bgr.shape[0] / bgr.shape[1])))
                    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 75])
                    keyframes.append({"episode": int(e), "label": label, "jpeg": base64.b64encode(buf.tobytes()).decode()})
                except Exception:
                    pass  # una que no se pudo leer se omite
    return {"repo_id": repo_id, "fps": meta.fps, "robot_type": meta.robot_type, "total_episodes": total, "joints": joints, "joint_units": shown,
            "tasks": list(tasks.values())[:10], "cameras": video_keys, "units": "degrees" if degrees else "converted to degrees with this robot's calibration",
            "episodes": out_eps, "keyframes": keyframes}


def half_spans(msg: dict) -> dict:
    """Medio recorrido en grados de cada articulación según la calibración guardada de este robot (para
    convertir -100..100 a grados). Se lee del robot de LeRobot sin conectarlo."""
    try:
        robot = make_robot(msg)
    except Exception:
        return {}
    return {j: h for j in joint_units(robot) if (h := half_span_degrees(robot, j))}


def dataset_info(root: Path) -> dict | None:
    info = root / "meta" / "info.json"
    if not info.exists():
        return None
    meta = json.loads(info.read_text())
    tasks = []
    tasks_file = root / "meta" / "tasks.jsonl"
    if tasks_file.exists():
        tasks = [json.loads(l).get("task") for l in tasks_file.read_text().splitlines() if l.strip()][:3]
    elif (root / "meta" / "tasks.parquet").exists():
        try:
            import pandas as pd

            df = pd.read_parquet(root / "meta" / "tasks.parquet")
            tasks = [str(t) for t in (df.index.tolist() if "task" not in df.columns else df["task"].tolist())][:3]
        except Exception:
            pass
    size = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
    return {
        "root": str(root), "episodes": meta.get("total_episodes", 0), "frames": meta.get("total_frames", 0),
        "fps": meta.get("fps"), "robot": meta.get("robot_type"), "tasks": tasks, "bytes": size,
        "cameras": [k.split(".")[-1] for k, f in meta.get("features", {}).items() if f.get("dtype") == "video"],
    }


def cmd_datasets(msg: dict) -> dict:
    """Datasets de LeRobot en las carpetas dadas (los grabados en la app y la caché de Hugging Face)."""
    out = []
    for folder in msg.get("roots", []):
        base = Path(folder).expanduser()
        if not base.exists():
            continue
        # Hasta dos niveles: <carpeta>/<nombre> y <carpeta>/<usuario>/<nombre> (caché del Hub).
        for meta in list(base.glob("*/meta/info.json")) + list(base.glob("*/*/meta/info.json")):
            root = meta.parent.parent
            if "calibration" in root.parts:
                continue
            info = dataset_info(root)
            if info:
                rel = root.relative_to(base)
                info["name"] = str(rel)
                info["source"] = "hub" if len(rel.parts) == 2 else "local"
                out.append(info)
    return {"datasets": out}


def cmd_delete_dataset(msg: dict) -> dict:
    root = Path(msg["root"])
    if not (root / "meta" / "info.json").exists():
        raise ValueError("That folder isn't a LeRobot dataset.")
    shutil.rmtree(root)
    return {}


# ---------------------------------------------------------------------------------------------
# Sesiones con el robot (una a la vez)
# ---------------------------------------------------------------------------------------------
class Session:
    kind = "session"

    def __init__(self, msg: dict):
        self.msg = msg
        self.stop_event = threading.Event()
        self.phase = "starting"
        self.error = None
        self.thread = threading.Thread(target=self._guarded, daemon=True)

    @property
    def active(self) -> bool:
        return self.thread.is_alive()

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()

    def control(self, action: str):
        pass

    def _guarded(self):
        try:
            self.run()
            self.phase = "done"
        except Exception as e:
            self.error = clean(e)
            self.phase = "error"
        finally:
            emit({"event": self.kind, **self.status(), "active": False})

    def status(self) -> dict:
        return {"phase": self.phase, "error": self.error}


def follower_args(msg: dict) -> list[str]:
    RobotConfig, _ = registries()
    args = [f"--robot.type={robot_type(msg)}", f"--robot.id={msg['follower_id']}"]
    if accepts(RobotConfig, robot_type(msg), "port"):
        args.append(f"--robot.port={msg['follower_port']}")
    return args


def leader_args(msg: dict) -> list[str]:
    _, TeleoperatorConfig = registries()
    args = [f"--teleop.type={teleop_type(msg)}", f"--teleop.id={msg['leader_id']}"]
    if accepts(TeleoperatorConfig, teleop_type(msg), "port"):
        args.append(f"--teleop.port={msg['leader_port']}")
    return args


def joints_of(obs: dict) -> dict:
    """Las posiciones de una observación de LeRobot (las claves «<articulación>.pos»)."""
    return {k.removesuffix(".pos"): round(float(v), 2) for k, v in obs.items() if k.endswith(".pos")}


class Teleop(Session):
    """El follower copia al leader (como lerobot-teleoperate). No graba nada."""

    kind = "teleop"

    def __init__(self, msg):
        super().__init__(msg)
        self.hz = 0.0
        self.joints = {}

    def run(self):
        import draccus
        from lerobot.scripts import lerobot_teleoperate as lt

        fps = int(self.msg.get("fps", 60))
        cfg = draccus.parse(lt.TeleoperateConfig, args=follower_args(self.msg) + leader_args(self.msg) + [f"--fps={fps}"])
        teleop = lt.make_teleoperator_from_config(cfg.teleop)
        robot = lt.make_robot_from_config(cfg.robot)
        tap, rap, _ = lt.make_default_processors()
        try:
            teleop.connect()
            robot.connect()
            self.phase = "running"
            last_emit = 0.0
            while not self.stop_event.is_set():
                t = time.perf_counter()
                obs = robot.get_observation()
                action = tap((teleop.get_action(), obs))
                robot.send_action(rap((action, obs)))
                time.sleep(max(0.0, 1 / fps - (time.perf_counter() - t)))
                self.hz = 0.9 * self.hz + 0.1 / max(time.perf_counter() - t, 1e-3)
                if time.monotonic() - last_emit > 0.2:
                    self.joints = joints_of(obs)
                    emit({"event": "teleop", **self.status(), "active": True})
                    last_emit = time.monotonic()
            self.phase = "stopping"
        finally:
            # Desconectar suelta los motores del follower, igual que Ctrl+C en la terminal.
            for device in (teleop, robot):
                try:
                    if device.is_connected:
                        device.disconnect()
                except Exception:
                    pass

    def status(self):
        return {**super().status(), "hz": round(self.hz), "joints": self.joints}


_record_session = None  # la grabación activa (lr.record no recibe contexto)


class Record(Session):
    """Graba demostraciones con lerobot-record: el follower copia al leader mientras se graba.

    Se reemplazan el teclado (→ ← Esc) por órdenes de la app y se envuelve record_loop para avisar la
    fase (grabando / reacomodando) y mandar la vista de la cámara.
    """

    kind = "record"

    def __init__(self, msg):
        super().__init__(msg)
        self.events = {"exit_early": False, "rerecord_episode": False, "stop_recording": False}
        self.episode = 0
        self.phase_t0 = time.monotonic()
        self.phase_limit = 0.0
        self.robot = None
        self.joints = {}

    def control(self, action):
        if action == "next":
            self.events["exit_early"] = True
        elif action == "redo":
            self.events["rerecord_episode"] = True
            self.events["exit_early"] = True

    def stop(self):
        self.events["stop_recording"] = True
        self.events["exit_early"] = True
        super().stop()

    def record_args(self) -> list[str]:
        m = self.msg
        cam = m["camera"]
        cameras = cameras_arg([("front", camera_config(cam["index"]))])
        args = follower_args(m) + [
            f"--robot.cameras={cameras}",
            f"--dataset.repo_id={m['repo_id']}",
            f"--dataset.root={m['root']}",
            "--dataset.push_to_hub=false",
            "--play_sounds=false",  # sin voz («Recording episode…», «Stop recording»…)
            f"--dataset.single_task={m['task']}",
            f"--dataset.num_episodes={int(m['num_episodes'])}",
            f"--dataset.episode_time_s={float(m['episode_time_s'])}",
            f"--dataset.reset_time_s={float(m['reset_time_s'])}",
        ] + leader_args(m)
        if m.get("resume"):
            args.append("--resume=true")
        return args

    def run(self):
        global _record_session
        import draccus
        from lerobot.scripts import lerobot_record as lr

        root = Path(self.msg["root"])
        done = 0
        if (root / "meta" / "info.json").exists():
            done = json.loads((root / "meta" / "info.json").read_text()).get("total_episodes", 0)
            self.msg["resume"] = done > 0
        if done == 0 and root.exists():
            shutil.rmtree(root)  # un intento anterior que no llegó a guardar ningún episodio
        self.episode = done
        cfg = draccus.parse(lr.RecordConfig, args=self.record_args())

        original_loop = lr.record_loop
        session = self

        def record_loop(**kwargs):
            session._enter(kwargs)
            try:
                return original_loop(**kwargs)
            finally:
                session.phase = "saving"
                session.phase_t0 = time.monotonic()
                session.phase_limit = 0

        lr.record_loop = record_loop
        lr.init_keyboard_listener = lambda: (None, session.events)
        _record_session = self
        pump = threading.Thread(target=self._pump, daemon=True)
        pump.start()
        try:
            lr.record(cfg)
        finally:
            lr.record_loop = original_loop
            _record_session = None
            # LeRobot lo suelta al final, pero después de codificar los videos: si eso falla, la cámara quedaría tomada.
            release(self.robot)
            self.robot = None

    def _enter(self, kwargs):
        robot = kwargs.get("robot")
        if robot is not None and not getattr(robot, "_curiosity", False):
            # Una pausa breve de la cámara USB no debe cortar toda la sesión.
            for cam in getattr(robot, "cameras", {}).values():
                cam.read_latest = functools.partial(cam.read_latest, max_age_ms=1500)
            robot._curiosity = True
        self.robot = robot
        dataset = kwargs.get("dataset")
        if dataset is not None:
            self.episode = dataset.num_episodes
        self.phase = "recording" if dataset is not None else "reset"
        self.phase_t0 = time.monotonic()
        self.phase_limit = float(kwargs.get("control_time_s") or 0)

    def _pump(self):
        """Avisos de estado (4 por segundo) y la vista de la cámara (4 cuadros por segundo)."""
        while self.active:
            emit({"event": "record", **self.status(), "active": True})
            robot = self.robot
            if robot is not None and robot.is_connected:
                jpeg = camera_frame(robot)
                if jpeg:
                    emit({"event": "frame", "jpeg": jpeg})
            time.sleep(0.25)

    def status(self):
        return {**super().status(), "episode": self.episode, "target": int(self.msg["num_episodes"]),
                "elapsed": round(time.monotonic() - self.phase_t0, 1), "limit": self.phase_limit}


def camera_config(index, width=640, height=480, fps=30):
    """Pide 640×480 a 30 fps y se queda con lo que la cámara entregue de verdad (la Osmo, p. ej., solo da
    1920×1080). LeRobot exige que coincida exacto, así que se mide antes de dárselo."""
    import cv2
    from lerobot.cameras.opencv import OpenCVCameraConfig

    cap = cv2.VideoCapture(int(index))
    try:
        if not cap.isOpened():
            raise ValueError(f"Couldn't open camera {index}.")
        cap.set(cv2.CAP_PROP_FPS, fps)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.read()
        w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        real_fps = int(round(cap.get(cv2.CAP_PROP_FPS) or fps))
    finally:
        cap.release()
    # La Osmo tarda más de 1 s (lo que LeRobot espera por defecto) en mandar su primera imagen.
    return OpenCVCameraConfig(index_or_path=int(index), width=w, height=h, fps=real_fps, warmup_s=3)


def cameras_arg(cams) -> str:
    """Las cámaras [(nombre, config)] para --robot.cameras, en JSON: así se leen bien sea cual sea el formato que
    draccus esté usando. Es un ajuste global, y LeRobot lo pasa a JSON un momento cada vez que lee una calibración
    (con `config_type("json")`): si eso pasa en otro hilo justo entonces, un valor en YAML queda como texto y
    falla con «'str' object has no attribute 'items'». El JSON también es YAML válido."""
    return json.dumps({name: {"type": "opencv", "index_or_path": c.index_or_path, "width": c.width, "height": c.height,
                              "fps": c.fps, "warmup_s": c.warmup_s} for name, c in cams})


def camera_configs(msg):
    """La cámara principal («front») y las demás («cam1»…), todas medidas igual con camera_config."""

    cam = msg["camera"]
    out = {"front": camera_config(cam["index"])}
    for i, index in enumerate(msg.get("extra_cameras") or [], start=1):
        out[f"cam{i}"] = camera_config(index)
    return out


class SimRecord(Session):
    """Demostraciones en la simulación: el leader real mueve el robot simulado (la app lo dibuja y manda
    su cámara y su estado) y se guarda un dataset de LeRobot igual al de lerobot-record. El follower real
    no se conecta: nada físico se mueve. Las articulaciones son las del leader, por nombre."""

    kind = "simrecord"

    def __init__(self, msg):
        super().__init__(msg)
        self.events = {"exit_early": False, "rerecord_episode": False, "stop_recording": False}
        self.episode = 0
        self.phase_t0 = time.monotonic()
        self.phase_limit = 0.0
        self.joints = {}       # el leader, en las unidades de `shown` (para mover la simulación)
        self.shown = {}        # unidad de cada articulación para la app: «deg» si se puede pasar a grados
        self.latest = None     # (imagen RGB, estado en grados) que mandó la app
        self.lock = threading.Lock()

    def control(self, action, payload=None):
        if action == "next":
            self.events["exit_early"] = True
        elif action == "redo":
            self.events["rerecord_episode"] = True
            self.events["exit_early"] = True
        elif action == "frame":
            import cv2
            import numpy as np

            img = cv2.imdecode(np.frombuffer(base64.b64decode(payload["jpeg"]), np.uint8), cv2.IMREAD_COLOR)
            if img is not None:
                h, w = self.size
                rgb = cv2.cvtColor(cv2.resize(img, (w, h)), cv2.COLOR_BGR2RGB)
                with self.lock:
                    self.latest = (rgb, {j: float(v) for j, v in payload["state"].items()})

    def stop(self):
        self.events["stop_recording"] = True
        self.events["exit_early"] = True
        super().stop()

    size = (480, 640)

    def run(self):
        from lerobot.datasets.lerobot_dataset import LeRobotDataset
        from lerobot.utils.feature_utils import combine_feature_dicts, hw_to_dataset_features

        m = self.msg
        fps = int(m.get("fps", 30))
        leader = make_leader(m)
        units = joint_units(leader)
        half = half_spans(m)
        # Lo que va de -100 a 100 y tiene calibración se muestra en grados; lo demás, en su escala.
        self.shown = {j: "deg" if u == "±100" and half.get(j) else u for j, u in units.items()}
        self.half = half
        to_norm = lambda state: {f"{j}.pos": state[j] / half[j] * 100 if self.shown[j] == "deg" else state[j] for j in units}
        joint_ft = {f"{j}.pos": float for j in units}
        features = combine_feature_dicts(hw_to_dataset_features(joint_ft, "action"),
                                         hw_to_dataset_features({**joint_ft, "front": (*self.size, 3)}, "observation"))
        root = Path(m["root"])
        done = 0
        if (root / "meta" / "info.json").exists():
            done = json.loads((root / "meta" / "info.json").read_text()).get("total_episodes", 0)
        if done == 0 and root.exists():
            shutil.rmtree(root)
        dataset = (LeRobotDataset.resume(m["repo_id"], root=root, image_writer_threads=4) if done
                   else LeRobotDataset.create(m["repo_id"], fps, features=features, root=root, robot_type=robot_type(m),
                                              use_videos=True, image_writer_threads=4))
        self.episode = dataset.num_episodes
        self.target = dataset.num_episodes + int(m["num_episodes"])
        try:
            leader.connect()
            target = self.target
            while dataset.num_episodes < target and not self.events["stop_recording"]:
                self._phase("recording", float(m["episode_time_s"]))
                self._loop(leader, fps, dataset, features, to_norm, m["task"], record=True)
                if self.events["rerecord_episode"]:
                    self.events["rerecord_episode"] = False
                    self.events["exit_early"] = False
                    dataset.clear_episode_buffer()
                    continue
                if dataset.has_pending_frames():
                    self.phase = "saving"
                    dataset.save_episode()
                    self.episode = dataset.num_episodes
                if self.events["stop_recording"] or dataset.num_episodes >= target:
                    break
                self._phase("reset", float(m["reset_time_s"]))
                self._loop(leader, fps, dataset, features, to_norm, m["task"], record=False)
        finally:
            self.phase = "saving"
            dataset.finalize()
            try:
                leader.disconnect()
            except Exception:
                pass

    def _phase(self, name, limit):
        self.phase, self.phase_t0, self.phase_limit = name, time.monotonic(), limit
        self.events["exit_early"] = False

    def _loop(self, leader, fps, dataset, features, to_norm, task, record):
        """Cada 1/fps: lee el leader (y lo manda a la app) y, si graba, guarda la última imagen y estado."""
        dt = 1 / fps
        while not self.events["exit_early"] and time.monotonic() - self.phase_t0 < self.phase_limit:
            t = time.perf_counter()
            action = leader.get_action()  # en la escala de cada motor, como lerobot-record
            self.joints = {j: round(action[f"{j}.pos"] / 100 * self.half[j] if u == "deg" else action[f"{j}.pos"], 2)
                           for j, u in self.shown.items()}
            emit({"event": "simrecord", **self.status(), "active": True})
            with self.lock:
                latest = self.latest
            if record and latest is not None:
                from lerobot.utils.feature_utils import build_dataset_frame

                image, state = latest
                obs = {**to_norm(state), "front": image}
                dataset.add_frame({**build_dataset_frame(features, obs, prefix="observation"),
                                   **build_dataset_frame(features, action, prefix="action"), "task": task})
            time.sleep(max(0.0, dt - (time.perf_counter() - t)))

    def status(self):
        return {**super().status(), "episode": self.episode, "target": getattr(self, "target", int(self.msg["num_episodes"])),
                "elapsed": round(time.monotonic() - self.phase_t0, 1), "limit": self.phase_limit, "joints": self.joints,
                "joint_names": list(self.shown), "units": self.shown}


class SkillPolicy:
    """Un modelo que entiende órdenes en palabras (SmolVLA, π0…; también ACT, que ignora la orden), cargado una
    vez y listo para usar dentro de la sesión en vivo: la IA dice «qué» y él hace el «cómo» a 30 Hz."""

    def __init__(self, path: str, cameras: list[str], joints: list[str], robot: str):
        import torch
        from lerobot.configs.policies import PreTrainedConfig
        from lerobot.configs.types import FeatureType
        from lerobot.policies.factory import get_policy_class, make_pre_post_processors

        local = Path(path).expanduser()
        source = str(local) if local.exists() else path  # una carpeta de esta Mac o un modelo del Hub
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        cfg = PreTrainedConfig.from_pretrained(source)
        cfg.pretrained_path = source
        cfg.device = self.device
        self.policy = get_policy_class(cfg.type).from_pretrained(source, config=cfg).to(self.device).eval()
        self.pre, self.post = make_pre_post_processors(
            cfg, pretrained_path=source, preprocessor_overrides={"device_processor": {"device": self.device}})
        self.path, self.type = path, cfg.type
        self.joints, self.robot = joints, robot
        # Cada cámara que espera el modelo toma una del robot, en orden (la principal primero).
        self.image_names = [k.removeprefix("observation.images.") for k, f in cfg.input_features.items()
                            if f.type == FeatureType.VISUAL]
        self.camera_map = {name: cameras[min(i, len(cameras) - 1)] for i, name in enumerate(self.image_names)} if cameras else {}
        self.note = (f"The model expects {len(self.image_names)} cameras ({', '.join(self.image_names)}) and only "
                     f"{len(cameras)} are on: the main one fills in for the rest.") if len(self.image_names) > len(cameras) else None

    def reset(self):
        self.policy.reset()
        for p in (self.pre, self.post):
            if hasattr(p, "reset"):
                p.reset()

    def act(self, obs: dict, instruction: str) -> dict:
        """Una observación del robot → los objetivos de cada articulación (en la unidad de cada una)."""
        import numpy as np
        import torch
        from lerobot.policies.utils import prepare_observation_for_inference

        frame = {"observation.state": np.array([obs[f"{j}.pos"] for j in self.joints], dtype=np.float32)}
        for name, key in self.camera_map.items():
            frame[f"observation.images.{name}"] = obs[key]
        batch = self.pre(prepare_observation_for_inference(frame, torch.device(self.device), instruction, self.robot))
        with torch.inference_mode():
            action = self.post(self.policy.select_action(batch))
        return dict(zip(self.joints, action.squeeze(0).float().cpu().tolist()))


class Live(Session):
    """El robot en vivo, sin leader: se queda firme en su pose y va hacia los objetivos que mande la app
    (la persona con los controles, o la IA después de que la persona aprueba), a velocidad limitada.
    Al terminar vuelve despacio a la pose en que empezó y suelta los motores.
    Las articulaciones y su unidad las da el robot: en grados donde se puede (use_degrees), si no 0–100 o ±100."""

    kind = "live"
    FPS = 30
    SPEED = 40.0       # grados por segundo como máximo
    UNIT_SPEED = 60.0  # unidades por segundo en las escalas 0–100 y ±100
    MARGIN = 3.0       # grados de margen dentro del rango calibrado

    def __init__(self, msg):
        super().__init__(msg)
        self.robot = None
        self.joints, self.targets, self.limits, self.start_pose = {}, {}, {}, {}
        self.units, self.names = {}, []
        self.lock = threading.Lock()
        self.camera_change = None  # nuevas cámaras extra, se aplican en el hilo del robot
        self.trajectory = None     # (inicio, [[t, j1..j6], ...]) que se está reproduciendo
        self.policy = None         # SkillPolicy cargado (se queda cargado entre órdenes)
        self.skill = None          # {instruction, t0, limit}: la orden que está haciendo el modelo
        self.skill_last = None     # cómo terminó la última: {instruction, reason, seconds}

    SKILL_SPEED = 90.0        # con un modelo, más rápido que a mano (sigue dentro del rango)
    SKILL_UNIT_SPEED = 150.0

    def load_skill(self, path):
        """Carga el modelo de órdenes (tarda: la primera vez lo baja del Hub)."""
        robot = self.robot
        if robot is None:
            raise ValueError("The robot isn't connected.")
        if self.skill:
            raise ValueError("The model is doing something. Stop it first.")
        if self.policy is None or self.policy.path != path:
            self.policy = None
            self.policy = SkillPolicy(path, list(robot.cameras), self.names, robot_type(self.msg))
        return {"type": self.policy.type, "device": self.policy.device, "cameras": self.policy.camera_map,
                "note": self.policy.note}

    def _end_skill(self, command, reason):
        """Termina la orden (con el candado tomado): el robot se queda donde está."""
        skill, self.skill = self.skill, None
        if skill:
            self.skill_last = {"instruction": skill["instruction"], "reason": reason,
                               "seconds": round(time.monotonic() - skill["t0"], 1)}
        self.targets = dict(command)

    def control(self, action, payload=None):
        with self.lock:
            if action in ("targets", "home", "trajectory") and self.skill:
                self.skill = None  # tocar los controles corta la orden del modelo (el bucle lo anota)
            if action == "skill":
                if self.policy is None:
                    raise ValueError("Load a model first.")
                self.trajectory = None
                self.policy.reset()
                self.skill = {"instruction": str(payload["instruction"]), "t0": time.monotonic(),
                              "limit": min(120.0, max(1.0, float(payload.get("seconds") or 15)))}
                self.skill_last = None
            elif action == "skill_stop":
                if self.skill:
                    self.skill = {**self.skill, "stopped": True}
            elif action == "targets":
                self.trajectory = None
                for j, v in (payload or {}).items():
                    if j in self.limits:
                        lo, hi = self.limits[j]
                        self.targets[j] = min(hi, max(lo, float(v)))
            elif action == "home":
                self.trajectory = None
                self.targets = dict(self.start_pose)
            elif action == "trajectory":
                self._start_trajectory(payload)
            elif action == "cameras":
                self.camera_change = [int(i) for i in payload or []]

    def look(self, width=768):
        """Una foto de cada cámara: [{camera, jpeg}]."""
        robot = self.robot
        if robot is None:
            raise ValueError("The robot isn't connected.")
        return [{"camera": key, "jpeg": jpeg} for key in robot.cameras
                if (jpeg := camera_frame(robot, key, width))]

    def run(self):
        robot = make_robot(self.msg, use_degrees=True, cameras=camera_configs(self.msg))
        try:
            robot.connect()
            self.robot = robot
            self.units = joint_units(robot)
            self.names = list(self.units)
            if not self.names:
                raise ValueError("This robot has no position joints to control live.")
            for j, unit in self.units.items():
                if unit == "deg":
                    half = half_span_degrees(robot, j)
                    if half is None:
                        raise ValueError(f"{j} has no calibration. Calibrate the robot first.")
                    self.limits[j] = (-(half - self.MARGIN), half - self.MARGIN)
                else:
                    self.limits[j] = (0.0, 100.0) if unit == "0-100" else (-100.0, 100.0)
            obs = robot.get_observation()
            self.start_pose = {j: float(obs[f"{j}.pos"]) for j in self.names}
            command = dict(self.start_pose)
            with self.lock:
                self.targets = dict(self.start_pose)
            self.phase = "running"
            self._loop(robot, command, until=lambda: self.stop_event.is_set())

            # Al terminar: de vuelta a la pose del principio, despacio, y después se sueltan los motores.
            self.phase = "returning"
            with self.lock:
                self.trajectory = None
                self.targets = dict(self.start_pose)
            deadline = time.monotonic() + 8
            self._loop(robot, command, until=lambda: time.monotonic() > deadline or self._settled(command))
        finally:
            self.robot = None
            release(robot)

    def _start_trajectory(self, payload):
        """Reproduce un tramo de una demostración: primero va despacio a su primer punto y luego lo sigue,
        a `speed` (0.25 a 1) de su velocidad original. Llamar con el candado tomado."""
        points = [list(map(float, p)) for p in (payload or {}).get("points", [])]
        if not points:
            return
        speed = min(1.0, max(0.25, float((payload or {}).get("speed", 0.5))))
        first = dict(zip(self.names, points[0][1:]))
        reach = max(abs(first[j] - self.joints.get(j, first[j])) for j in first)
        approach = reach / 30 + 0.3
        t0 = points[0][0]
        timeline = [[0.0] + [self.joints.get(j, first.get(j, 0.0)) for j in self.names]]
        timeline += [[approach + (p[0] - t0) / speed] + p[1:] for p in points]
        self.trajectory = (time.monotonic(), timeline)

    def _follow_trajectory(self):
        """Los objetivos del momento según la trayectoria (interpolada), dentro del rango."""
        start, timeline = self.trajectory
        now = time.monotonic() - start
        if now >= timeline[-1][0]:
            pose, self.trajectory = timeline[-1][1:], None
        else:
            k = next(i for i, p in enumerate(timeline) if p[0] > now)
            a, b = timeline[k - 1], timeline[k]
            f = (now - a[0]) / max(1e-6, b[0] - a[0])
            pose = [x + (y - x) * f for x, y in zip(a[1:], b[1:])]
        for j, v in zip(self.names, pose):
            lo, hi = self.limits[j]
            self.targets[j] = min(hi, max(lo, v))

    def _apply_cameras(self, robot, indexes):
        """Agrega o quita cámaras extra con el robot conectado. Una que no abre se avisa y se omite."""
        from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig

        for key in [k for k in robot.cameras if k != "front"]:
            try:
                robot.cameras[key].disconnect()
            except Exception:
                pass
            del robot.cameras[key]
        for i, index in enumerate(indexes, start=1):
            try:
                cam = OpenCVCamera(camera_config(index))
                cam.connect()
                robot.cameras[f"cam{i}"] = cam
            except Exception as e:
                self.error = f"Camera {index} didn't open: {clean(e)}"

    def _settled(self, command):
        with self.lock:
            return all(abs(command[j] - self.targets[j]) < 0.5 for j in self.names)

    def _loop(self, robot, command, until):
        dt = 1 / self.FPS
        last_emit = last_frame = 0.0
        seen = None  # la orden del modelo en la vuelta anterior
        while not until():
            t = time.perf_counter()
            obs = None
            with self.lock:
                skill = self.skill
                if seen and skill is None and self.skill_last is None:
                    # La cortaron los controles: se anota sin pisar los objetivos nuevos.
                    self.skill_last = {"instruction": seen["instruction"], "reason": "interrupted",
                                       "seconds": round(time.monotonic() - seen["t0"], 1)}
                if skill and (skill.get("stopped") or self.stop_event.is_set()
                              or time.monotonic() - skill["t0"] > skill["limit"]):
                    self._end_skill(command, "stopped" if skill.get("stopped") or self.stop_event.is_set() else "time")
                    skill = None
            seen = skill
            if skill:
                # El modelo mira y da el próximo objetivo (cada tanto piensa un tramo y la vuelta tarda más).
                try:
                    obs = robot.get_observation()
                    goal = self.policy.act(obs, skill["instruction"])
                except Exception as e:
                    goal = None
                    with self.lock:
                        self._end_skill(command, f"error: {clean(e)}")
                    seen = skill = None
                with self.lock:
                    if goal and self.skill is skill:
                        for j, v in goal.items():
                            lo, hi = self.limits[j]
                            self.targets[j] = min(hi, max(lo, v))
            with self.lock:
                if self.trajectory:
                    self._follow_trajectory()
                targets = dict(self.targets)
                change, self.camera_change = self.camera_change, None
            if change is not None:
                self._apply_cameras(robot, change)
            for j in self.names:
                degrees = self.units[j] == "deg"
                if skill:
                    speed = self.SKILL_SPEED if degrees else self.SKILL_UNIT_SPEED
                else:
                    speed = self.SPEED if degrees else self.UNIT_SPEED
                command[j] += max(-speed * dt, min(speed * dt, targets[j] - command[j]))
            robot.send_action({f"{j}.pos": command[j] for j in self.names})
            now = time.monotonic()
            if obs is not None:
                self.joints = joints_of(obs)
            if now - last_emit > 0.1:  # 10 por segundo: el modelo 3D lo sigue suave
                if obs is None:
                    self.joints = joints_of(robot.get_observation())
                emit({"event": "live", **self.status(), "active": True})
                last_emit = now
            if now - last_frame > 0.25:
                for key in robot.cameras:
                    jpeg = camera_frame(robot, key)
                    if jpeg:
                        emit({"event": "frame", "camera": key, "jpeg": jpeg})
                last_frame = now
            time.sleep(max(0.0, dt - (time.perf_counter() - t)))

    def status(self):
        with self.lock:
            targets = {j: round(v, 1) for j, v in self.targets.items()}
            skill = self.skill
        policy = self.policy
        return {**super().status(), "joints": self.joints, "targets": targets, "playing": self.trajectory is not None,
                "joint_names": self.names, "units": self.units,
                "skill": {"instruction": skill["instruction"], "elapsed": round(time.monotonic() - skill["t0"], 1),
                          "limit": skill["limit"]} if skill else None,
                "skill_last": self.skill_last,
                "skill_model": {"path": policy.path, "type": policy.type, "device": policy.device,
                                "note": policy.note} if policy else None,
                "limits": {j: [round(lo, 1), round(hi, 1)] for j, (lo, hi) in self.limits.items()}}


def trim_bars(img, dark=12):
    """Quita las franjas negras de los bordes (imagen metida en un cuadro de otra forma)."""
    rows = (img.mean(axis=(1, 2)) > dark).nonzero()[0]
    cols = (img.mean(axis=(0, 2)) > dark).nonzero()[0]
    if len(rows) < img.shape[0] * 0.2 or len(cols) < img.shape[1] * 0.2:
        return img  # casi todo oscuro: es la escena, no franjas
    return img[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1]


def camera_frame(robot, key="front", width=480):
    """El último cuadro de una cámara del robot, chico y en JPEG (base64), o None."""
    import cv2

    try:
        rgb = robot.cameras[key].read_latest()
    except Exception:
        return None
    bgr = trim_bars(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
    bgr = cv2.resize(bgr, (width, int(width * bgr.shape[0] / bgr.shape[1])))
    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 70 if width <= 480 else 80])
    return base64.b64encode(buf.tobytes()).decode() if ok else None


class Rollout(Session):
    """El robot usa un modelo entrenado (como lerobot-rollout) durante `duration` segundos.
    Al terminar o al detenerlo, LeRobot lo devuelve a su pose inicial y suelta los motores."""

    kind = "rollout"

    def __init__(self, msg):
        super().__init__(msg)
        self.t0 = time.monotonic()
        self.robot = None
        self.joints = {}
        self.units = {}

    def camera_names(self) -> list[str]:
        """Los nombres de cámara con que se entrenó el modelo (p. ej. «up» y «side» en svla_so101_pickplace)."""
        features = json.loads((Path(self.msg["policy_path"]) / "config.json").read_text()).get("input_features", {})
        return [k.removeprefix("observation.images.") for k, f in features.items() if f.get("type") == "VISUAL"]

    def args(self) -> list[str]:
        m = self.msg
        cam = m["camera"]
        # Cada cámara toma el nombre que el modelo espera: la principal el primero, las extra los demás.
        names = self.camera_names() or ["front"]
        extras = list(m.get("extra_cameras") or [])
        if len(names) > 1 + len(extras):
            missing = len(names) - 1 - len(extras)
            raise ValueError(
                f"This model was trained with {len(names)} cameras ({', '.join(names)}) and only 1 + {len(extras)} are on. "
                f"Pick {missing} more in step 3 → Cameras and arm…. "
                f"Order: the main camera is «{names[0]}», then {', '.join('«' + n + '»' for n in names[1:])}.")
        indexes = [int(cam["index"]), *extras]
        cameras = cameras_arg([(n, camera_config(i)) for n, i in zip(names, indexes)])
        RobotConfig, _ = registries()
        args = ["--strategy.type=base", *follower_args(m), f"--robot.cameras={cameras}", f"--task={m['task']}",
                f"--duration={float(m['duration'])}"]
        if accepts(RobotConfig, robot_type(m), "max_relative_target"):
            args.append(f"--robot.max_relative_target={float(m.get('max_relative_target', 10))}")
        return args

    def config(self):
        import draccus
        from lerobot.configs import parser
        from lerobot.rollout import RolloutConfig

        path = Path(self.msg["policy_path"])
        if not (path / "config.json").exists():
            raise ValueError(f"Can't find the model at {path}.")
        # Fuera de la terminal, LeRobot lee --policy.path de un registro interno, no de sys.argv.
        parser._config_path_args["policy"] = str(path)
        return draccus.parse(RolloutConfig, args=self.args())

    def run(self):
        from lerobot.rollout import build_rollout_context, create_strategy

        cfg = self.config()
        strategy = ctx = None
        pump = threading.Thread(target=self._pump, daemon=True)
        pump.start()
        try:
            ctx = build_rollout_context(cfg, self.stop_event)
            robot = ctx.hardware.robot_wrapper.inner
            for cam in robot.cameras.values():
                cam.read_latest = functools.partial(cam.read_latest, max_age_ms=1500)
            # La pose para el modelo 3D sale de las lecturas que el modelo ya hace en cada paso: leer los
            # motores aparte, desde otro hilo, chocaría con él en el mismo cable.
            observe = robot.get_observation

            def get_observation(*args, **kwargs):
                obs = observe(*args, **kwargs)
                self.joints = joints_of(obs)
                return obs

            robot.get_observation = get_observation
            self.units = joint_units(robot)
            self.robot = robot
            strategy = create_strategy(cfg.strategy)
            strategy.setup(ctx)
            if not self.stop_event.is_set():
                self.phase, self.t0 = "running", time.monotonic()
                strategy.run(ctx)
            self.phase, self.t0 = "returning", time.monotonic()
        finally:
            try:
                if strategy is not None and ctx is not None:
                    strategy.teardown(ctx)  # vuelve a la pose inicial y suelta los motores
            finally:
                # Aunque el cierre de LeRobot falle a mitad, motores y cámaras quedan libres.
                release(ctx.hardware.robot_wrapper.inner if ctx is not None else None)
                self.robot = None

    def _pump(self):
        while self.active:
            emit({"event": "rollout", **self.status(), "active": True})
            robot = self.robot
            if robot is not None and robot.is_connected:
                for key in robot.cameras:
                    jpeg = camera_frame(robot, key)
                    if jpeg:
                        emit({"event": "frame", "camera": key, "jpeg": jpeg})
            time.sleep(0.25)

    def status(self):
        robot = self.robot
        return {**super().status(), "elapsed": round(time.monotonic() - self.t0, 1), "limit": float(self.msg["duration"]),
                "joints": self.joints, "joint_names": list(self.joints), "units": self.units,
                "cameras": list(robot.cameras) if robot is not None else []}


# ---------------------------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------------------------
current: Session | None = None
QUERIES = {"hello": cmd_hello, "calibrations": cmd_calibrations, "robot_types": cmd_robot_types, "snapshot": cmd_snapshot, "preflight": cmd_preflight, "study": cmd_study,
           "datasets": cmd_datasets, "delete_dataset": cmd_delete_dataset}
SESSIONS = {"teleop": Teleop, "record": Record, "rollout": Rollout, "live": Live, "simrecord": SimRecord}


def handle(msg: dict) -> dict:
    global current
    cmd = msg.get("cmd")
    if cmd in QUERIES:
        return QUERIES[cmd](msg)
    if cmd in SESSIONS:
        if current is not None and current.active:
            raise ValueError("Something is already running on the robot. Stop it first.")
        current = SESSIONS[cmd](msg)
        current.start()
        return {}
    if cmd == "stop":
        if current is not None and current.active:
            current.stop()
        return {}
    if cmd == "sim_frame":
        if isinstance(current, SimRecord) and current.active:
            current.control("frame", msg)
        return {}
    if cmd in ("next", "redo"):
        if current is not None and current.active:
            current.control(cmd)
        return {}
    if cmd in ("live_targets", "live_home", "live_cameras", "live_trajectory"):
        if not (isinstance(current, Live) and current.active):
            raise ValueError("The robot isn't live.")
        payload = {"live_targets": msg.get("targets"), "live_cameras": msg.get("extra_cameras"),
                   "live_trajectory": {"points": msg.get("points"), "speed": msg.get("speed")}}.get(cmd)
        current.control(cmd.removeprefix("live_"), payload)
        return {}
    if cmd in ("live_skill_load", "live_skill", "live_skill_stop"):
        if not (isinstance(current, Live) and current.active):
            raise ValueError("The robot isn't live.")
        if cmd == "live_skill_load":
            return current.load_skill(str(msg["policy_path"]))
        current.control(cmd.removeprefix("live_"), {"instruction": msg.get("instruction"), "seconds": msg.get("seconds")})
        return {}
    if cmd == "live_look":
        if not (isinstance(current, Live) and current.active):
            raise ValueError("The robot isn't live.")
        return {"images": current.look()}
    raise ValueError(f"Unknown command: {cmd}")


def preload():
    """Carga LeRobot una vez, en el hilo principal: importarlo desde varios hilos a la vez rompe numpy."""
    import cv2  # noqa: F401
    import draccus  # noqa: F401
    import numpy  # noqa: F401
    import pandas  # noqa: F401
    from lerobot.scripts import lerobot_record, lerobot_rollout, lerobot_teleoperate  # noqa: F401


def main():
    preload()
    emit({"event": "ready"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        rid = msg.get("id")

        def work(msg=msg, rid=rid):
            try:
                emit({"id": rid, "ok": True, **handle(msg)})
            except SystemExit:  # draccus sale así cuando un argumento no le sirve
                emit({"id": rid, "ok": False, "error": "LeRobot didn't accept the settings (check the data)."})
            except Exception as e:
                emit({"id": rid, "ok": False, "error": clean(e)})

        # Las consultas lentas (subir al Hub, una foto) no deben trabar las órdenes de parar.
        threading.Thread(target=work, daemon=True).start()
    if current is not None and current.active:
        current.stop()
        current.thread.join(timeout=20)


if __name__ == "__main__":
    main()

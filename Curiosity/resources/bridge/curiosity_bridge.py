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


JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
CALIBRATION_ROOT = Path.home() / ".cache" / "huggingface" / "lerobot" / "calibration"


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


def cmd_snapshot(msg: dict) -> dict:
    """Una foto de la cámara `index` (JPEG en base64), para elegir la correcta."""
    import cv2

    cap = cv2.VideoCapture(int(msg["index"]))
    try:
        frame = None
        for _ in range(8):  # los primeros cuadros suelen salir oscuros
            ok, frame = cap.read()
        if frame is None:
            raise ValueError("La cámara no entregó imagen (¿la está usando otro programa?).")
        frame = cv2.resize(frame, (480, int(480 * frame.shape[0] / frame.shape[1])))
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
        return {"jpeg": base64.b64encode(buf.tobytes()).decode()}
    finally:
        cap.release()


def cmd_preflight(msg: dict) -> dict:
    """Revisa cada pieza antes de grabar o probar, sin mover nada (solo lee los motores):
    follower, leader, que estén en poses parecidas y la cámara. Devuelve una lista de revisiones
    {key, state: ok · warn · fail, detail} y una foto de la cámara."""
    from lerobot.robots import make_robot_from_config
    from lerobot.robots.so_follower import SO101FollowerConfig

    checks, poses, jpeg = [], {}, None

    def arm(key, obj):
        bus = obj.bus
        try:
            bus.connect()
            if not bus.is_calibrated:
                checks.append({"key": key, "state": "fail", "detail": "La calibración guardada no coincide con los motores. Calibra de nuevo en la terminal."})
                return
            poses[key] = bus.sync_read("Present_Position")
            checks.append({"key": key, "state": "ok", "detail": "Responden los 6 motores y está calibrado."})
        except Exception as e:
            text = clean(e)
            if "busy" in text.lower() or "resource" in text.lower():
                detail = "El puerto está ocupado: cierra otros programas que usen el robot."
            elif "missing" in text.lower() or "found" in text.lower() or "No such file" in text:
                detail = "No responde. Revisa el cable USB y que la fuente esté encendida."
            else:
                detail = text
            checks.append({"key": key, "state": "fail", "detail": detail})
        finally:
            try:
                bus.disconnect(disable_torque=False)
            except Exception:
                pass

    arm("follower", make_robot_from_config(SO101FollowerConfig(port=msg["follower_port"], id=msg["follower_id"])))
    if msg.get("leader_port"):
        from lerobot.teleoperators import make_teleoperator_from_config
        from lerobot.teleoperators.so_leader import SO101LeaderConfig

        arm("leader", make_teleoperator_from_config(SO101LeaderConfig(port=msg["leader_port"], id=msg["leader_id"])))
        if "follower" in poses and "leader" in poses:
            diff = max(abs(poses["follower"][j] - poses["leader"][j]) for j in JOINTS if j != "gripper")
            if diff > 25:
                checks.append({"key": "pose", "state": "warn",
                               "detail": f"El leader y el follower están en poses distintas ({diff:.0f}°). Al empezar, el follower saltará a la pose del leader: acércalas."})
            else:
                checks.append({"key": "pose", "state": "ok", "detail": "El leader y el follower están en poses parecidas."})

    cam = msg["camera"]
    try:
        import cv2
        from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig

        c = OpenCVCamera(OpenCVCameraConfig(index_or_path=int(cam["index"]), width=int(cam["width"]),
                                            height=int(cam["height"]), fps=int(cam["fps"])))
        c.connect()
        try:
            frame = c.read()
        finally:
            c.disconnect()
        small = cv2.resize(frame[:, :, ::-1], (480, int(480 * frame.shape[0] / frame.shape[1])))
        ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 75])
        jpeg = base64.b64encode(buf.tobytes()).decode()
        checks.append({"key": "camera", "state": "ok", "detail": f"Entrega imagen a {cam['width']}×{cam['height']}, {cam['fps']} fps."})
    except Exception as e:
        text = clean(e)
        if "fps" in text:
            detail = f"No da {cam['fps']} fps. Elige otra cámara en Ajustes del robot."
        elif "open" in text.lower() or "authoriz" in text.lower():
            detail = "No se pudo abrir: revisa el permiso de cámara de Curiosity y que ningún otro programa la esté usando."
        else:
            detail = text
        checks.append({"key": "camera", "state": "fail", "detail": detail})

    for i, index in enumerate(msg.get("extra_cameras") or [], start=1):
        try:
            from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig

            c = OpenCVCamera(native_camera_config(index))
            c.connect()
            try:
                frame = c.read()
            finally:
                c.disconnect()
            checks.append({"key": f"cam{i}", "state": "ok", "detail": f"Entrega imagen ({frame.shape[1]}×{frame.shape[0]})."})
        except Exception as e:
            checks.append({"key": f"cam{i}", "state": "fail",
                           "detail": f"No respondió ({clean(e)}). Quítala en Ajustes del robot o revisa su cable."})
    return {"checks": checks, "jpeg": jpeg}


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
    names = (meta.features.get("observation.state", {}).get("names") or [])
    names = [n.removesuffix(".pos") for n in names]
    if not set(JOINTS) <= set(names):
        raise ValueError(f"Este dataset no es de un SO-100/101 (articulaciones: {', '.join(names) or 'ninguna'}).")
    order = [names.index(j) for j in JOINTS]
    video_keys = list(meta.video_keys)

    states = np.asarray(ds.hf_dataset["observation.state"], dtype=float)[:, order]
    episodes_col = np.asarray(ds.hf_dataset["episode_index"])
    times = np.asarray(ds.hf_dataset["timestamp"], dtype=float)
    body = states[:, :5]
    degrees = np.abs(body).max() > 110  # con use_degrees los valores pasan de ±100; si no, van de -100 a 100
    half = half_spans(msg.get("follower_id"))
    to_deg = (lambda row: row) if degrees else (lambda row: [v / 100 * half[j] if j != "gripper" else v for j, v in zip(JOINTS, row)])

    tasks = {int(i): str(t) for t, i in zip(meta.tasks.index, meta.tasks["task_index"])} if hasattr(meta.tasks, "index") else {}
    out_eps, keyframes = [], []
    for e in picks:
        rows = np.nonzero(episodes_col == e)[0]
        if len(rows) == 0:
            continue
        t0 = times[rows[0]]
        step = max(1, int(round(meta.fps / 10)))  # 10 por segundo alcanza para reproducir
        traj = [[round(float(times[r] - t0), 2)] + [round(float(v), 1) for v in to_deg(states[r])] for r in rows[::step]]
        grip = states[rows, 5]
        events, closing = [], None
        smooth = np.convolve(grip, np.ones(5) / 5, mode="same")
        diff = np.diff(smooth)
        for k in range(1, len(diff)):
            sign = -1 if diff[k] < -0.4 else (1 if diff[k] > 0.4 else 0)
            if sign and sign != closing:
                events.append({"t": round(float(times[rows[k]] - t0), 2), "gripper": "cierra" if sign < 0 else "abre",
                               "row": int(rows[k])})
                closing = sign
        task_index = int(np.asarray(ds.hf_dataset["task_index"])[rows[0]]) if "task_index" in ds.hf_dataset.column_names else 0
        out_eps.append({"episode": int(e), "task": tasks.get(task_index, ""), "duration_s": round(float(times[rows[-1]] - t0), 1),
                        "trajectory": traj, "gripper_events": [{k: v for k, v in ev.items() if k != "row"} for ev in events]})
        if len(keyframes) < 12 and video_keys:
            moments = [("inicio", int(rows[0]))] + [(f"pinza {ev['gripper']} ({ev['t']} s)", ev["row"]) for ev in events[:3]] + [("final", int(rows[-1]))]
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
    return {"repo_id": repo_id, "fps": meta.fps, "robot_type": meta.robot_type, "total_episodes": total,
            "tasks": list(tasks.values())[:10], "cameras": video_keys, "units": "grados" if degrees else "convertido a grados con la calibración de este robot",
            "episodes": out_eps, "keyframes": keyframes}


def half_spans(follower_id):
    """Medio recorrido en grados de cada articulación según la calibración guardada (para convertir -100..100)."""
    out = {j: 90.0 for j in JOINTS}
    for path in (CALIBRATION_ROOT / "robots").glob(f"*/{follower_id}.json") if follower_id else []:
        for j, c in json.loads(path.read_text()).items():
            if j in out:
                out[j] = (c["range_max"] - c["range_min"]) / 2 * 360 / 4095
        break
    return out


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
        raise ValueError("Esa carpeta no es un dataset de LeRobot.")
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
    return ["--robot.type=so101_follower", f"--robot.port={msg['follower_port']}", f"--robot.id={msg['follower_id']}"]


def leader_args(msg: dict) -> list[str]:
    return ["--teleop.type=so101_leader", f"--teleop.port={msg['leader_port']}", f"--teleop.id={msg['leader_id']}"]


def joints_of(obs: dict) -> dict:
    return {j: round(float(obs[f"{j}.pos"]), 2) for j in JOINTS if f"{j}.pos" in obs}


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
        cameras = (f"{{ front: {{type: opencv, index_or_path: {int(cam['index'])}, width: {int(cam['width'])}, "
                   f"height: {int(cam['height'])}, fps: {int(cam['fps'])}}} }}")
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


def native_camera_config(index):
    """Una cámara extra con la resolución y fps que ella misma ofrece (cada cámara y cada Mac son distintas).
    LeRobot exige fijarlos, así que se leen primero. Muy grandes se bajan a 1280 de ancho."""
    import cv2
    from lerobot.cameras.opencv import OpenCVCameraConfig

    cap = cv2.VideoCapture(int(index))
    try:
        if not cap.isOpened():
            raise ValueError(f"No se pudo abrir la cámara {index}.")
        w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        fps = int(round(cap.get(cv2.CAP_PROP_FPS) or 30))
        if h > w:
            # Algunas (p. ej. la Osmo) entregan un cuadro vertical con la imagen horizontal al centro y franjas
            # negras: pidiendo el formato horizontal llega la imagen completa.
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, h)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, w)
            w2, h2 = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            if w2 > h2:
                w, h = w2, h2
        if w > 1280:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, round(1280 * h / w))
            w2, h2 = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            if w2 == 1280:
                w, h = w2, h2
    finally:
        cap.release()
    return OpenCVCameraConfig(index_or_path=int(index), width=w, height=h, fps=fps)


def camera_configs(msg):
    """La cámara principal («front», con su resolución fija) y las demás («cam1»…, como vengan)."""
    from lerobot.cameras.opencv import OpenCVCameraConfig

    cam = msg["camera"]
    out = {"front": OpenCVCameraConfig(index_or_path=int(cam["index"]), width=int(cam["width"]),
                                       height=int(cam["height"]), fps=int(cam["fps"]))}
    for i, index in enumerate(msg.get("extra_cameras") or [], start=1):
        out[f"cam{i}"] = native_camera_config(index)
    return out


class SimRecord(Session):
    """Demostraciones en la simulación: el leader real mueve el SO-101 simulado (la app lo dibuja y manda
    su cámara y su estado) y se guarda un dataset de LeRobot igual al de lerobot-record. El follower real
    no se conecta: nada físico se mueve."""

    kind = "simrecord"

    def __init__(self, msg):
        super().__init__(msg)
        self.events = {"exit_early": False, "rerecord_episode": False, "stop_recording": False}
        self.episode = 0
        self.phase_t0 = time.monotonic()
        self.phase_limit = 0.0
        self.joints = {}       # el leader, en grados (para mover la simulación)
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
        from lerobot.teleoperators import make_teleoperator_from_config
        from lerobot.teleoperators.so_leader import SO101LeaderConfig
        from lerobot.utils.feature_utils import build_dataset_frame, combine_feature_dicts, hw_to_dataset_features

        m = self.msg
        fps = int(m.get("fps", 30))
        half = half_spans(m.get("follower_id"))
        to_norm = lambda deg: {f"{j}.pos": (deg[j] / half[j] * 100 if j != "gripper" else deg[j]) for j in JOINTS}
        joint_ft = {f"{j}.pos": float for j in JOINTS}
        features = combine_feature_dicts(hw_to_dataset_features(joint_ft, "action"),
                                         hw_to_dataset_features({**joint_ft, "front": (*self.size, 3)}, "observation"))
        root = Path(m["root"])
        done = 0
        if (root / "meta" / "info.json").exists():
            done = json.loads((root / "meta" / "info.json").read_text()).get("total_episodes", 0)
        if done == 0 and root.exists():
            shutil.rmtree(root)
        dataset = (LeRobotDataset.resume(m["repo_id"], root=root, image_writer_threads=4) if done
                   else LeRobotDataset.create(m["repo_id"], fps, features=features, root=root, robot_type="so101_follower",
                                              use_videos=True, image_writer_threads=4))
        self.episode = dataset.num_episodes
        self.target = dataset.num_episodes + int(m["num_episodes"])
        leader = make_teleoperator_from_config(SO101LeaderConfig(port=m["leader_port"], id=m["leader_id"]))
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
            action = leader.get_action()  # -100..100 (la pinza 0..100), como lerobot-record
            half = half_spans(self.msg.get("follower_id"))
            self.joints = {j: round(action[f"{j}.pos"] / 100 * half[j] if j != "gripper" else action[f"{j}.pos"], 2) for j in JOINTS}
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
                "elapsed": round(time.monotonic() - self.phase_t0, 1), "limit": self.phase_limit, "joints": self.joints}


class Live(Session):
    """El robot en vivo, sin leader: se queda firme en su pose y va hacia los objetivos que mande la app
    (la persona con los controles, o la IA después de que la persona aprueba), a velocidad limitada.
    Al terminar vuelve despacio a la pose en que empezó y suelta los motores.
    Articulaciones en grados (la pinza, de 0 a 100)."""

    kind = "live"
    FPS = 30
    SPEED = 40.0         # grados por segundo como máximo
    GRIPPER_SPEED = 60.0  # unidades (0-100) por segundo
    MARGIN = 3.0          # grados de margen dentro del rango calibrado

    def __init__(self, msg):
        super().__init__(msg)
        self.robot = None
        self.joints, self.targets, self.limits, self.start_pose = {}, {}, {}, {}
        self.lock = threading.Lock()
        self.camera_change = None  # nuevas cámaras extra, se aplican en el hilo del robot
        self.trajectory = None     # (inicio, [[t, j1..j6], ...]) que se está reproduciendo

    def control(self, action, payload=None):
        with self.lock:
            if action == "targets":
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
            raise ValueError("El robot no está conectado.")
        return [{"camera": key, "jpeg": jpeg} for key in robot.cameras
                if (jpeg := camera_frame(robot, key, width))]

    def run(self):
        from lerobot.cameras.opencv import OpenCVCameraConfig
        from lerobot.robots import make_robot_from_config
        from lerobot.robots.so_follower import SO101FollowerConfig

        cfg = SO101FollowerConfig(port=self.msg["follower_port"], id=self.msg["follower_id"], use_degrees=True,
                                  cameras=camera_configs(self.msg))
        robot = make_robot_from_config(cfg)
        try:
            robot.connect()
            self.robot = robot
            for j, c in robot.calibration.items():
                if j == "gripper":
                    self.limits[j] = (0.0, 100.0)
                else:
                    half = (c.range_max - c.range_min) / 2 * 360 / 4095 - self.MARGIN
                    self.limits[j] = (-half, half)
            obs = robot.get_observation()
            self.start_pose = {j: float(obs[f"{j}.pos"]) for j in JOINTS}
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
            try:
                if robot.is_connected:
                    robot.disconnect()
            except Exception:
                pass

    def _start_trajectory(self, payload):
        """Reproduce un tramo de una demostración: primero va despacio a su primer punto y luego lo sigue,
        a `speed` (0.25 a 1) de su velocidad original. Llamar con el candado tomado."""
        points = [list(map(float, p)) for p in (payload or {}).get("points", [])]
        if not points:
            return
        speed = min(1.0, max(0.25, float((payload or {}).get("speed", 0.5))))
        first = dict(zip(JOINTS, points[0][1:]))
        reach = max(abs(first[j] - self.joints.get(j, first[j])) for j in JOINTS)
        approach = reach / 30 + 0.3
        t0 = points[0][0]
        timeline = [[0.0] + [self.joints.get(j, first[j]) for j in JOINTS]]
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
        for j, v in zip(JOINTS, pose):
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
                cam = OpenCVCamera(native_camera_config(index))
                cam.connect()
                robot.cameras[f"cam{i}"] = cam
            except Exception as e:
                self.error = f"La cámara {index} no abrió: {clean(e)}"

    def _settled(self, command):
        with self.lock:
            return all(abs(command[j] - self.targets[j]) < 0.5 for j in JOINTS)

    def _loop(self, robot, command, until):
        dt = 1 / self.FPS
        last_emit = last_frame = 0.0
        while not until():
            t = time.perf_counter()
            with self.lock:
                if self.trajectory:
                    self._follow_trajectory()
                targets = dict(self.targets)
                change, self.camera_change = self.camera_change, None
            if change is not None:
                self._apply_cameras(robot, change)
            for j in JOINTS:
                step = (self.GRIPPER_SPEED if j == "gripper" else self.SPEED) * dt
                command[j] += max(-step, min(step, targets[j] - command[j]))
            robot.send_action({f"{j}.pos": command[j] for j in JOINTS})
            now = time.monotonic()
            if now - last_emit > 0.1:  # 10 por segundo: el modelo 3D lo sigue suave
                obs = robot.get_observation()
                self.joints = joints_of(obs)
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
        return {**super().status(), "joints": self.joints, "targets": targets, "playing": self.trajectory is not None,
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

    def args(self) -> list[str]:
        m = self.msg
        cam = m["camera"]
        cameras = (f"{{ front: {{type: opencv, index_or_path: {int(cam['index'])}, width: {int(cam['width'])}, "
                   f"height: {int(cam['height'])}, fps: {int(cam['fps'])}}} }}")
        return ["--strategy.type=base", *follower_args(m),
                f"--robot.max_relative_target={float(m.get('max_relative_target', 10))}",
                f"--robot.cameras={cameras}", f"--task={m['task']}", f"--duration={float(m['duration'])}"]

    def config(self):
        import draccus
        from lerobot.configs import parser
        from lerobot.rollout import RolloutConfig

        path = Path(self.msg["policy_path"])
        if not (path / "config.json").exists():
            raise ValueError(f"No encuentro el modelo en {path}.")
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
                elif ctx is not None and ctx.hardware.robot_wrapper.inner.is_connected:
                    ctx.hardware.robot_wrapper.inner.disconnect()
            finally:
                self.robot = None

    def _pump(self):
        while self.active:
            emit({"event": "rollout", **self.status(), "active": True})
            if self.robot is not None and self.robot.is_connected:
                jpeg = camera_frame(self.robot)
                if jpeg:
                    emit({"event": "frame", "jpeg": jpeg})
            time.sleep(0.25)

    def status(self):
        return {**super().status(), "elapsed": round(time.monotonic() - self.t0, 1), "limit": float(self.msg["duration"])}


# ---------------------------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------------------------
current: Session | None = None
QUERIES = {"hello": cmd_hello, "calibrations": cmd_calibrations, "snapshot": cmd_snapshot, "preflight": cmd_preflight, "study": cmd_study,
           "datasets": cmd_datasets, "delete_dataset": cmd_delete_dataset}
SESSIONS = {"teleop": Teleop, "record": Record, "rollout": Rollout, "live": Live, "simrecord": SimRecord}


def handle(msg: dict) -> dict:
    global current
    cmd = msg.get("cmd")
    if cmd in QUERIES:
        return QUERIES[cmd](msg)
    if cmd in SESSIONS:
        if current is not None and current.active:
            raise ValueError("Ya hay algo corriendo con el robot. Detenlo primero.")
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
            raise ValueError("El robot no está en vivo.")
        payload = {"live_targets": msg.get("targets"), "live_cameras": msg.get("extra_cameras"),
                   "live_trajectory": {"points": msg.get("points"), "speed": msg.get("speed")}}.get(cmd)
        current.control(cmd.removeprefix("live_"), payload)
        return {}
    if cmd == "live_look":
        if not (isinstance(current, Live) and current.active):
            raise ValueError("El robot no está en vivo.")
        return {"images": current.look()}
    raise ValueError(f"Orden desconocida: {cmd}")


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
                emit({"id": rid, "ok": False, "error": "LeRobot no aceptó la configuración (revisa los datos)."})
            except Exception as e:
                emit({"id": rid, "ok": False, "error": clean(e)})

        # Las consultas lentas (subir al Hub, una foto) no deben trabar las órdenes de parar.
        threading.Thread(target=work, daemon=True).start()
    if current is not None and current.active:
        current.stop()
        current.thread.join(timeout=20)


if __name__ == "__main__":
    main()

"""Puente entre la app Curiosity y LeRobot.

La app lo corre con el Python donde está instalado LeRobot y le habla por líneas JSON:
  entrada (stdin):  {"id": 1, "cmd": "teleop", ...}       una orden por línea
  salida (stdout):  {"id": 1, "ok": true, ...}             la respuesta a esa orden
                    {"event": "record", ...}               avisos mientras corre algo

Hace lo mismo que los comandos de LeRobot, con su mismo código:
  lerobot-teleoperate   → cmd "teleop"
  lerobot-record        → cmd "record" (demostraciones con el leader)
  lerobot-rollout       → cmd "rollout" (el robot usa un modelo entrenado)
y además: calibraciones guardadas, cámaras, una foto de prueba y los datasets locales.
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
import traceback
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


def camera_names() -> list[str]:
    """Cámaras en el orden en que OpenCV las numera en macOS (ordenadas por uniqueID)."""
    try:
        import AVFoundation as AVF

        types = [AVF.AVCaptureDeviceTypeBuiltInWideAngleCamera, AVF.AVCaptureDeviceTypeExternal]
        session = AVF.AVCaptureDeviceDiscoverySession.discoverySessionWithDeviceTypes_mediaType_position_(
            types, AVF.AVMediaTypeVideo, AVF.AVCaptureDevicePositionUnspecified)
        devices = sorted(session.devices(), key=lambda d: str(d.uniqueID()))
        return [str(d.localizedName()) for d in devices]
    except Exception:
        return []


def cmd_cameras(_: dict) -> dict:
    return {"cameras": [{"index": i, "name": n} for i, n in enumerate(camera_names())]}


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
    return {"checks": checks, "jpeg": jpeg}


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


def cmd_push_dataset(msg: dict) -> dict:
    from lerobot.datasets import LeRobotDataset

    LeRobotDataset(msg["repo_id"], root=msg["root"]).push_to_hub(private=bool(msg.get("private", True)))
    return {"url": f"https://huggingface.co/datasets/{msg['repo_id']}"}


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
            traceback.print_exc(file=sys.stderr)
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


def camera_frame(robot):
    """El último cuadro de la cámara del robot, chico y en JPEG (base64), o None."""
    import cv2

    try:
        rgb = robot.cameras["front"].read_latest()
    except Exception:
        return None
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    bgr = cv2.resize(bgr, (480, int(480 * bgr.shape[0] / bgr.shape[1])))
    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 70])
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
QUERIES = {"hello": cmd_hello, "calibrations": cmd_calibrations, "cameras": cmd_cameras, "snapshot": cmd_snapshot, "preflight": cmd_preflight,
           "datasets": cmd_datasets, "push_dataset": cmd_push_dataset, "delete_dataset": cmd_delete_dataset}
SESSIONS = {"teleop": Teleop, "record": Record, "rollout": Rollout}


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
    if cmd in ("next", "redo"):
        if current is not None and current.active:
            current.control(cmd)
        return {}
    if cmd == "validate":
        # Revisa los argumentos sin conectar nada (para probar el puente).
        if msg.get("policy_path"):
            Rollout(msg).config()
        else:
            import draccus
            from lerobot.scripts import lerobot_record as lr

            draccus.parse(lr.RecordConfig, args=Record(msg).record_args())
        return {}
    raise ValueError(f"Orden desconocida: {cmd}")


def preload():
    """Carga LeRobot una vez, en el hilo principal: importarlo desde varios hilos a la vez rompe numpy."""
    import cv2  # noqa: F401
    import draccus  # noqa: F401
    import numpy  # noqa: F401
    import pandas  # noqa: F401
    from lerobot.scripts import lerobot_record, lerobot_rollout, lerobot_teleoperate  # noqa: F401


class _Tee:
    """Copia stderr a un archivo: lo que LeRobot escribe queda en logs/bridge.log."""

    def __init__(self, *streams):
        self.streams = streams

    def write(self, text):
        for s in self.streams:
            s.write(text)
            s.flush()
        return len(text)

    def flush(self):
        for s in self.streams:
            s.flush()


def main():
    import os

    if os.environ.get("CURIOSITY_LOG"):
        sys.stderr = _Tee(sys.__stderr__, open(os.environ["CURIOSITY_LOG"], "a", buffering=1))
        sys.stderr.write(f"\n--- {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n")
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
                traceback.print_exc(file=sys.stderr)
                emit({"id": rid, "ok": False, "error": clean(e)})

        # Las consultas lentas (subir al Hub, una foto) no deben trabar las órdenes de parar.
        threading.Thread(target=work, daemon=True).start()
    if current is not None and current.active:
        current.stop()
        current.thread.join(timeout=20)


if __name__ == "__main__":
    main()

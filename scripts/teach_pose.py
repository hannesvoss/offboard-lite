#!/usr/bin/env python3
"""Teach-in von UR5-Posen per FreeDrive -> robot.yaml `poses:`-Block.

Zweck (laeuft im husky-offboard-lite-Container, verbunden per Zenoh mit dem
ECHTEN Roboter): den Arm per Hand in eine Pose fuehren (FreeDrive), die
aktuellen Gelenkwinkel abgreifen und im exakten YAML-Format ausgeben, das
`husky-custom-setup/robot.yaml` unter `manipulators.arms[].poses` erwartet. Von
dort werden sie beim naechsten `generate_semantic_description`-Lauf zu benannten
MoveIt-Group-States (SRDF `<group_state>`), die in RViz/MoveIt anwaehlbar sind.

FreeDrive richtig aktivieren (2 Dinge, sonst bleibt der Arm steif obwohl der
Mode-Manager "aktiv" meldet):
  1. `ur_state_manager/prepare` -> Arm bestromen, **Bremsen loesen**, RUNNING +
     ExternalControl. Ohne laufendes ExternalControl erreicht der FreeDrive-
     URScript den Arm nicht.
  2. Auf `mode/freedrive` schalten (aktiviert den `freedrive_mode_controller`)
     UND dauerhaft `enable_freedrive_mode=true` (std_msgs/Bool, ~2 Hz) publishen.
     Der `ur_controllers/FreedriveModeController` faellt von SELBST wieder ab,
     wenn kein True mehr kommt.

Joint-Quelle: auf a200-0553 verschiebt der custom-setup die Live-Arm-JSB-Ausgabe
nach `/<ns>/manipulators/joint_states` (platform/joint_states ist nur ein Relay).
Darum lesen wir standardmaessig die manipulators-Topic. Der Node spinnt DAUERHAFT
im Hintergrund -> die Werte sind beim Erfassen immer frisch (kein spin_once-
Latenz-/Stale-Queue-Problem).

Braucht nur rclpy + std_srvs + std_msgs + sensor_msgs (alles im ROS-Jazzy-Base).
"""
import argparse
import os
import sys
import threading
import time

import rclpy
from rclpy.callback_groups import ReentrantCallbackGroup
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from sensor_msgs.msg import JointState
from std_msgs.msg import Bool
from std_srvs.srv import Trigger

# Kanonische UR-Gelenkreihenfolge, wie sie der Clearpath-Manipulator-Generator
# in den SRDF-Group-State schreibt. Der tf_prefix (Default arm_0_) wird
# vorangestellt; abgegriffen wird NACH diesem Namen aus dem JointState.
UR_JOINT_ORDER = [
    "shoulder_pan_joint",
    "shoulder_lift_joint",
    "elbow_joint",
    "wrist_1_joint",
    "wrist_2_joint",
    "wrist_3_joint",
]


class PoseTeacher(Node):
    def __init__(self, ns, manip_ns, joints_topic, tf_prefix, freedrive_rate):
        super().__init__("teach_pose")
        self.tf_prefix = tf_prefix
        self.joint_names = [tf_prefix + j for j in UR_JOINT_ORDER]
        self.freedrive_rate = freedrive_rate
        self._latest = {}       # name -> position
        self._last_stamp = 0.0  # monotonic time der letzten vollstaendigen Arm-Nachricht
        self._lock = threading.Lock()
        self.cbg = ReentrantCallbackGroup()

        self.create_subscription(JointState, joints_topic, self._on_js, 10,
                                 callback_group=self.cbg)

        mm = f"/{manip_ns}/ur_controller_mode_manager"
        self.cli_prepare = self.create_client(
            Trigger, f"/{manip_ns}/ur_state_manager/prepare", callback_group=self.cbg)
        self.cli_freedrive = self.create_client(
            Trigger, f"{mm}/mode/freedrive", callback_group=self.cbg)
        self.cli_trajectory = self.create_client(
            Trigger, f"{mm}/mode/trajectory", callback_group=self.cbg)

        # FreeDrive-Keepalive: dauerhaft True publishen, sonst faellt der
        # FreedriveModeController wieder ab. Timer laeuft im Hintergrund-Executor.
        self.enable_pub = self.create_publisher(
            Bool, f"/{manip_ns}/freedrive_mode_controller/enable_freedrive_mode", 10)
        self._freedrive_active = threading.Event()
        self.create_timer(1.0 / max(freedrive_rate, 0.1), self._keepalive_cb,
                          callback_group=self.cbg)

    def _on_js(self, msg: JointState):
        with self._lock:
            for name, pos in zip(msg.name, msg.position):
                self._latest[name] = pos
            if all(n in self._latest for n in self.joint_names):
                self._last_stamp = time.monotonic()

    def have_all(self):
        with self._lock:
            return all(n in self._latest for n in self.joint_names)

    def missing(self):
        with self._lock:
            return [n for n in self.joint_names if n not in self._latest]

    def snapshot(self):
        """Aktuelle 6 Armgelenke in kanonischer Reihenfolge (+Alter in s) oder (None,None)."""
        with self._lock:
            if not all(n in self._latest for n in self.joint_names):
                return None, None
            age = time.monotonic() - self._last_stamp
            return [float(self._latest[n]) for n in self.joint_names], age

    def _keepalive_cb(self):
        if self._freedrive_active.is_set():
            self.enable_pub.publish(Bool(data=True))

    def _call(self, client, label, timeout=30.0):
        if not client.wait_for_service(timeout_sec=5.0):
            self.get_logger().warn(
                f"Service {client.srv_name} nicht sichtbar ({label} uebersprungen). "
                "Laeuft ur_state_manager / ur_controller_mode_manager auf dem Roboter?")
            return False
        fut = client.call_async(Trigger.Request())
        done = threading.Event()
        fut.add_done_callback(lambda _f: done.set())  # feuert aus dem Executor-Thread
        if not done.wait(timeout) or fut.result() is None:
            self.get_logger().warn(f"{label}: keine Antwort (Timeout).")
            return False
        res = fut.result()
        if not res.success:
            self.get_logger().warn(f"{label} fehlgeschlagen: {res.message}")
            return False
        self.get_logger().info(f'{label} ok: {res.message}')
        return True

    # --- oeffentliche Ablaufschritte ---------------------------------------
    def prepare(self):
        """Arm bestromen + Bremsen loesen + ExternalControl (idempotent)."""
        return self._call(self.cli_prepare, "ur_state_manager/prepare")

    def enable_freedrive(self):
        ok = self._call(self.cli_freedrive, "mode/freedrive")
        self._freedrive_active.set()  # Keepalive AN (auch falls Service-Antwort zickt)
        return ok

    def disable_freedrive_to_trajectory(self):
        self._freedrive_active.clear()
        try:
            self.enable_pub.publish(Bool(data=False))  # sauber abfallen lassen
        except Exception:
            pass
        return self._call(self.cli_trajectory, "mode/trajectory")


def _approx_equal(a, b, tol=1e-3):
    return a is not None and b is not None and all(abs(x - y) <= tol for x, y in zip(a, b))


def format_poses_block(poses, with_header=True):
    """poses: [(name, [6 floats]), ...] -> robot.yaml-kompatibler YAML-Text.

    Einrueckung 1:1 wie in husky-custom-setup/robot.yaml
    (poses: @6, '- name:' @8, joints: @10).
    """
    lines = []
    if with_header:
        lines.append("      poses:")
    for name, joints in poses:
        arr = ", ".join(repr(j) for j in joints)
        lines.append(f"        - name: {name}")
        lines.append(f"          joints: [{arr}]")
    return "\n".join(lines) + "\n"


HELP = """\
Befehle:
  <name>        aktuelle Pose unter <name> merken (z.B. 'home', 'pick_ready')
  list          gemerkte Posen zeigen
  del <name>    eine gemerkte Pose entfernen
  now           aktuelle Gelenkwinkel roh anzeigen (ohne zu merken; zeigt Alter)
  save          poses:-Block ausgeben (und in --output schreiben, falls gesetzt)
  help          diese Hilfe
  quit / Ctrl-D beenden (schaltet auf mode/trajectory zurueck)
"""


def main():
    ns_default = os.environ.get("CLEARPATH_NS", "a200_0553")
    ap = argparse.ArgumentParser(description="UR5-Posen per FreeDrive teachen -> robot.yaml poses:")
    ap.add_argument("--ns", default=ns_default, help=f"Roboter-Namespace (Default: {ns_default})")
    ap.add_argument("--manip-ns", default=None,
                    help="Manipulators-Namespace (Default: <ns>/manipulators)")
    ap.add_argument("--joints-topic", default=None,
                    help="JointState-Topic (Default: /<ns>/manipulators/joint_states = Live-Arm-JSB)")
    ap.add_argument("--tf-prefix", default="arm_0_", help="Gelenk-Praefix (Default: arm_0_)")
    ap.add_argument("--no-freedrive", action="store_true",
                    help="FreeDrive NICHT selbst schalten (Arm anderweitig fuehren)")
    ap.add_argument("--no-prepare", action="store_true",
                    help="ur_state_manager/prepare NICHT aufrufen (Arm ist schon bereit)")
    ap.add_argument("--freedrive-rate", type=float, default=2.0,
                    help="Publish-Rate fuer enable_freedrive_mode in Hz (Default: 2.0)")
    ap.add_argument("--output", "-o", default=None,
                    help="Datei, in die der poses:-Block geschrieben wird")
    args = ap.parse_args()

    manip_ns = (args.manip_ns or f"{args.ns}/manipulators").strip("/")
    # Live-Arm-Feedback liegt auf manipulators/joint_states (custom-setup Phase 2);
    # platform/joint_states ist nur ein Relay -> direkt die Quelle lesen.
    joints_topic = args.joints_topic or f"/{manip_ns}/joint_states"

    rclpy.init()
    node = PoseTeacher(args.ns, manip_ns, joints_topic, args.tf_prefix, args.freedrive_rate)

    # Executor DAUERHAFT im Hintergrund -> joint_states/Timer/Services laufen,
    # auch waehrend der Hauptthread in input() blockiert.
    executor = MultiThreadedExecutor()
    executor.add_node(node)
    spin_thread = threading.Thread(target=executor.spin, daemon=True)
    spin_thread.start()

    print(f"[teach-pose] NS={args.ns}  manip_ns=/{manip_ns}  joints_topic={joints_topic}  "
          f"tf_prefix={args.tf_prefix}")
    print(f"[teach-pose] warte auf {joints_topic} ...")
    t0 = time.time()
    while rclpy.ok() and not node.have_all() and time.time() - t0 < 15.0:
        time.sleep(0.2)
    if not node.have_all():
        print(f"[teach-pose] WARN: nicht alle Armgelenke gesehen. Fehlt: {node.missing()}")
        print("            Topic/Namespace/tf-prefix pruefen (Roboter an? Zenoh verbunden?).")
        print(f"            Alternativ: --joints-topic /{args.ns}/platform/joint_states")
    else:
        print("[teach-pose] Gelenke sichtbar.")

    if not args.no_freedrive:
        if not args.no_prepare:
            print("[teach-pose] prepare: Arm bestromen + Bremsen loesen + ExternalControl ...")
            if not node.prepare():
                print("[teach-pose] WARN: prepare nicht erfolgreich -> FreeDrive bleibt evtl. wirkungslos "
                      "(Arm bestromt? E-Stop frei? ur_state_manager sichtbar?).")
        print("[teach-pose] schalte FreeDrive ein (+ enable_freedrive_mode-Keepalive) ...")
        node.enable_freedrive()
        print(f"[teach-pose] Arm sollte jetzt handfuehrbar sein (Keepalive @ {args.freedrive_rate} Hz).")
        print("[teach-pose] TEST: Arm von Hand bewegen und 'now' tippen - die Zahlen MUESSEN sich aendern.")
        print("[teach-pose] Aendern sie sich nicht: FreeDrive greift nicht (Bremsen? ExternalControl?).")
        print("[teach-pose] WARNUNG: Arm kann durch Schwerkraft leicht nachsacken -> festhalten.")
    else:
        print("[teach-pose] --no-freedrive: FreeDrive muss anderweitig aktiv sein.")

    poses = []  # (name, [6])
    print(HELP)

    def flush_save():
        if not poses:
            print("[teach-pose] keine Posen gemerkt.")
            return
        block = format_poses_block(poses)
        print("\n# ---- fuer husky-custom-setup/robot.yaml unter dem UR5-Arm einfuegen ----")
        print(block)
        if args.output:
            with open(args.output, "w") as f:
                f.write(block)
            print(f"[teach-pose] geschrieben nach {args.output}")

    try:
        while True:
            try:
                line = input("pose> ").strip()
            except EOFError:
                print()
                break
            if not line:
                continue
            cmd = line.split()
            key = cmd[0].lower()

            if key in ("quit", "exit", "q"):
                break
            elif key == "help":
                print(HELP)
            elif key == "list":
                if not poses:
                    print("  (keine)")
                for n, j in poses:
                    print(f"  {n}: [{', '.join(f'{x:.4f}' for x in j)}]")
            elif key == "now":
                snap, age = node.snapshot()
                if snap is None:
                    print(f"  keine vollstaendigen Gelenkdaten (fehlt: {node.missing()})")
                else:
                    warn = "  <-- STALE!" if age is not None and age > 1.0 else ""
                    print(f"  [{', '.join(f'{x:.6f}' for x in snap)}]  (Alter {age:.2f}s){warn}")
            elif key == "del":
                if len(cmd) < 2:
                    print("  Nutzung: del <name>")
                    continue
                target = cmd[1]
                before = len(poses)
                poses[:] = [(n, j) for (n, j) in poses if n != target]
                print("  entfernt." if len(poses) < before else f"  '{target}' nicht gefunden.")
            elif key == "save":
                flush_save()
            else:
                # Alles andere = Posenname.
                name = cmd[0]
                snap, age = node.snapshot()
                if snap is None:
                    print(f"  FEHLER: keine vollstaendigen Gelenkdaten (fehlt: {node.missing()}). "
                          "Nicht gemerkt.")
                    continue
                if age is not None and age > 1.0:
                    print(f"  WARN: Gelenkdaten sind {age:.1f}s alt (Topic still?) - trotzdem gemerkt.")
                # Warnen, wenn identisch zu einer bereits gemerkten Pose -> Arm hat
                # sich nicht bewegt / FreeDrive greift nicht.
                dup = next((n for n, j in poses if _approx_equal(j, snap)), None)
                if dup is not None:
                    print(f"  WARN: identisch zu '{dup}' (<1e-3 rad) - hat sich der Arm bewegt? "
                          "FreeDrive aktiv? (Test: Arm schieben + 'now').")
                poses[:] = [(n, j) for (n, j) in poses if n != name]  # gleicher Name ersetzt
                poses.append((name, snap))
                print(f"  gemerkt '{name}': [{', '.join(f'{x:.4f}' for x in snap)}]  (Alter {age:.2f}s)")
    except KeyboardInterrupt:
        print("\n[teach-pose] abgebrochen.")
    finally:
        flush_save()
        if not args.no_freedrive:
            print("[teach-pose] FreeDrive aus, schalte zurueck auf mode/trajectory (JTC) ...")
            node.disable_freedrive_to_trajectory()
        executor.shutdown()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()

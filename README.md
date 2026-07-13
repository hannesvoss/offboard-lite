# husky-offboard-lite

Schlankes Offboard-Image (ROS 2 Jazzy), das sich per Zenoh mit dem Husky verbindet.
Einziger Zweck: **MoveIt in RViz öffnen** und das auf dem
Roboter bereits laufende `move_group` grafisch bedienen (Plan & Execute für den
UR5). RViz läuft im Browser (noVNC).

## Basis-Image
Dieses Image baut auf dem gemeinsamen [`husky-offboard-base`](https://github.com/CLAIRLab-HAW/husky-offboard-base)
auf (Clearpath apt-Repo, noVNC/Desktop-Stack, noVNC-Scaling-Patch,
`rg6_description`-Build, `/usr/local/bin/start-desktop.sh`, gemeinsame ENV-Defaults).
Im Dockerfile:
```dockerfile
ARG BASE_IMAGE=ghcr.io/clairlab-haw/husky-offboard-base:jazzy
FROM ${BASE_IMAGE}
```
Default ist das **GHCR-Image** (ein Base-Build, überall gecacht). Für einen
lokalen Build ohne Registry-Pull die Base vorher selbst bauen
(`../husky-offboard-base`) und `BASE_IMAGE` überschreiben:
```bash
docker compose -f docker-compose.lan.yml build \
  --build-arg BASE_IMAGE=husky-offboard-base:jazzy
# oder:  export BASE_IMAGE=husky-offboard-base:jazzy  (Compose-Default greift)
```
Für reproduzierbare Builds den Base-Digest pinnen (`FROM ...@sha256:...`).

## Warum das ohne Clearpath-Stack funktioniert
Auf dem Roboter ist `manipulators.moveit.enable: true` → **`move_group` läuft
dort** und stellt bereit:
- `/a200_0553/robot_description` (URDF, vom `robot_state_publisher`)
- `/a200_0553/robot_description_semantic` (SRDF, vom `move_group`)
- die `/a200_0553/move_action`-Action + Planning-Scene-Topics

Das `moveit-rviz`-Skript **zieht URDF + SRDF beim Start per Parameter-Service**
vom Roboter (`robot_state_publisher.robot_description` +
`move_group.robot_description_semantic`) und gibt sie als lokale Parameter an
RViz. Planungs-Goals gehen an das `move_group` des Roboters (`move_action`). Der
Container muss also **kein** `move_group`, **keine** Clearpath-Generatoren,
**kein** `robot.yaml` und **kein** Gazebo mitbringen.

> Warum Param-Service statt Live-Topic: die gelatchte `robot_description`-String-
> Topic wird über die Zenoh-Bridge nicht zuverlässig an spät verbundene
> Subscriber ausgeliefert (RViz sah ein leeres URDF → `XML_ERROR_EMPTY_DOCUMENT`).
> Der Parameter-Service liefert das vom Roboter fertig berechnete Modell direkt.

## Was drin ist
Feature | **husky-offboard-lite** |
|---|---|
| Zenoh-Anbindung an den Roboter | ✅ |
| noVNC-Desktop | ✅ |
| `clearpath-desktop` / `-simulator` (Gazebo, viz) | ❌ |
| Clearpath **`*-description`** (Meshes) | ✅ (nur Descriptions) |
| Clearpath-Generatoren + `robot.yaml`-Mount | ❌ |
| move_group **im Container** (remote-MoveIt) | ❌ (nutzt das des Roboters) |
| rg6-/UR-Treiber-Build, foxglove | ❌ (nur `rg6_description`-Meshes) |
| **RViz + MoveIt-MotionPlanning-Plugin** | ✅ |

Installiert werden: `rviz2`, `moveit-ros-visualization`, `moveit-kinematics`,
`rmw-zenoh-cpp`, die `*-description`-Mesh-Pakete (UR5, Husky-Platform, Mounts,
Sensors, Manipulators, RealSense) + `rg6_description` aus Source (Greifer) + der
noVNC-Desktop.

## Build & Run
```bash
# 1) ROBOT_ZENOH_ENDPOINT in docker-compose.lan.yml auf die LAN-IP:Port des
#    Roboter-Zenoh-Routers setzen (Port ist standardmäßig 7447).
# 2) starten:
docker compose -f docker-compose.lan.yml up --build
# 3) Browser öffnen:
#    http://localhost:6080/vnc.html
# 4) im fluxbox-Desktop einen xterm öffnen (Rechtsklick -> Applications -> xterm)
#    und ausführen:
moveit-rviz
```
`moveit-rviz` prüft kurz, ob `/a200_0553/move_group` im Graphen sichtbar ist,
und startet dann RViz mit vorkonfiguriertem MotionPlanning-Panel.

### Variante: direkt auf dem Roboter (`docker-compose.robot.yml`)
Statt offboard vom Laptop kann derselbe Container **auf dem Roboter** laufen. Er
teilt sich dann per `network_mode: host` den Netzwerk-Stack und nutzt den bereits
laufenden Zenoh-Router des Roboters (`localhost:7447`) — **kein** eigener
`rmw_zenohd`, **kein** `ROBOT_ZENOH_ENDPOINT` (`ZENOH_LOCAL=1` erledigt das).
```bash
# auf dem Roboter bauen+starten (nativ x86_64!):
docker compose -f docker-compose.robot.yml up --build
# vom Laptop-Browser:
#   http://<robot-ip>:6080/vnc.html  -> xterm -> moveit-rviz
```
Zu bedenken:
- **CPU-Architektur:** auf dem **Roboter** bauen (x86_64). Ein auf Apple-Silicon
  gebautes Image (arm64) läuft dort nicht ohne `docker buildx --platform linux/amd64`.
- **Host-OS egal:** der Container bringt Jazzy selbst mit → läuft auch auf dem
  Ubuntu-Server-22.04-Host, ohne ihn anzufassen.
- **Last:** RViz rendert mit Software-GL (llvmpipe, CPU-hungrig) und konkurriert
  mit `move_group`/Controllern/Perception. Nur bei Bedarf starten (kein Autostart),
  damit die 125-Hz-Arm-Regelung nicht leidet. Übers Netz wandern dann VNC-Pixel
  statt ROS-Daten.

## Einmalige Verdrahtungs-Checks (wichtig)
Weil hier **nichts generiert** wird, hängt alles an den Live-Topics/-Frames des
Roboters. Falls das Modell nicht erscheint oder das Panel leer bleibt, in dieser
Reihenfolge prüfen (im noVNC-xterm):

1. **Graph + Modell-Parameter sichtbar?** `moveit-rviz` holt URDF/SRDF per
   Parameter-Service. Manuell prüfen:
   ```bash
   ros2 node list | grep -E 'move_group|robot_state_publisher'   # richtige Node-Namen?
   ros2 param get /a200_0553/robot_state_publisher robot_description | head -c 120
   ros2 param get /a200_0553/move_group robot_description_semantic | head -c 120
   ```
   Leer/Fehler → Zenoh/Netz: stimmt `ROBOT_ZENOH_ENDPOINT`? Roboter erreichbar
   (`ping`)? Läuft `rmw_zenohd` (`cat /tmp/zenohd.log`)? Heißen die Nodes anders,
   per `RSP_NODE=/... MG_NODE=/... moveit-rviz` überschreiben.

2. **TF-Namespace.** Clearpath publiziert TF **namespaced** (`/a200_0553/tf`,
   `/a200_0553/tf_static`). `moveit-rviz` remappt `/tf` + `/tf_static` daher
   standardmäßig dorthin — sonst „No tf data" und **kein Planen möglich**.
   Publiziert dein Setup TF doch global, abschalten mit `TF_REMAP=0 moveit-rviz`.
   Bleibt das Modell „ohne Transform" stehen, `Fixed Frame` in RViz auf einen
   vorhandenen Frame stellen (z. B. `base_link` oder `arm_0_base_link`).

3. **Planungsgruppen-Name** (nur für den interaktiven Ziehmarker). Der echte
   Name steht im SRDF:
   ```bash
   ros2 topic echo /a200_0553/robot_description_semantic --once | grep '<group '
   ```
   Ist er nicht in `config/kinematics.yaml` enthalten, dort als weiteren
   Schlüssel ergänzen (Neustart von `moveit-rviz`). Ohne lokale IK bleibt MoveIt
   trotzdem bedienbar: Tab **Joints**, **Update**, **Plan** & **Execute**.

## Posen teachen für `robot.yaml` (`teach-pose`)
Im noVNC-xterm liegt neben `moveit-rviz` das Skript **`teach-pose`**. Damit
fährt man den UR5 **per FreeDrive** von Hand in eine Pose und bekommt die
Gelenkwinkel im exakten YAML-Format, das `husky-custom-setup/robot.yaml` unter
`manipulators.arms[].poses` erwartet — von dort werden sie beim nächsten
Clearpath-Generatorlauf zu benannten **MoveIt-Group-States** (in RViz/MoveIt als
Named-Position anwählbar).

```bash
teach-pose                    # FreeDrive an, dann Posen teachen
teach-pose -o /tmp/poses.yaml # zusätzlich in Datei schreiben
teach-pose --no-freedrive     # FreeDrive nicht selbst schalten
```
Ablauf im Prompt (`pose>`):
- Arm von Hand in Position bringen, dann **Namen eintippen** (`home`,
  `pick_ready`, …) → aktuelle Gelenkwinkel werden gemerkt.
- `list` / `del <name>` / `now` (Rohwerte) / `save` (Block ausgeben) /
  `quit` (oder Ctrl-D).
- Beim Beenden wird **immer auf `mode/trajectory` (JTC) zurückgeschaltet**, damit
  MoveIt-Execute wieder funktioniert.

**Wie FreeDrive korrekt aktiviert wird** (sonst meldet der Mode-Manager „aktiv",
der Arm bleibt aber steif): `teach-pose` macht dasselbe wie `husky-demo-imitate`:
1. **`ur_state_manager/prepare`** — Arm bestromen, **Bremsen lösen**, RUNNING +
   ExternalControl. Ohne laufendes ExternalControl erreicht der FreeDrive-URScript
   den Arm nicht → Arm rührt sich nicht. (Abschaltbar mit `--no-prepare`.)
2. **`mode/freedrive`** aktivieren **und dauerhaft `enable_freedrive_mode=true`**
   (`std_msgs/Bool`, ~2 Hz) publishen — der `ur_controllers/FreedriveModeController`
   fällt von selbst wieder ab, wenn kein `true` mehr kommt. `teach-pose` hält das
   in einem Hintergrund-Thread (Rate über `--freedrive-rate`).

`teach-pose` liest **`/<ns>/manipulators/joint_states`** (die Live-Arm-JSB-Quelle;
auf a200-0553 verschiebt der custom-setup den Arm-Output dorthin,
`platform/joint_states` ist nur ein Relay). Der Node **spinnt dauerhaft im
Hintergrund**, damit die Werte beim Erfassen immer frisch sind. Die Gelenkauswahl
erfolgt **nach Namen** (`arm_0_*`), nicht nach Array-Reihenfolge. Andere Quelle
per `--joints-topic`. Voraussetzung: der Arm ist eingeschaltet (E-Stop frei) und
der `arm_controllers.launch.py`-Stack (inkl. `freedrive_mode_controller`) +
`ur_state_manager` laufen auf dem Roboter (auf a200-0553 als Boot-Service).
Ausgabe dann unter dem UR5-Arm in `robot.yaml` einfügen und mit
`generate_semantic_description` neu generieren (s. unten).

**Troubleshooting: alle Posen kommen identisch heraus.** Dann hat sich der Arm
physisch nicht bewegt (FreeDrive greift nicht) oder es wird eine tote Quelle
gelesen. Test: nach dem Start `now` tippen, Arm von Hand schieben, wieder `now` —
**die Zahlen müssen sich ändern**. Ändern sie sich nicht:
- Bremsen/ExternalControl nicht aktiv → `prepare` schlug fehl (E-Stop frei? Arm
  bestromt? Teach-Panel „External Control" running?).
- In einem zweiten xterm gegenprüfen, welche Topic live ist:
  `ros2 topic echo /<ns>/manipulators/joint_states --field position` vs
  `ros2 topic echo /<ns>/platform/joint_states --field position` (Arm schieben).

> **Achtung:** In FreeDrive kann der Arm durch die Schwerkraft leicht
> nachsacken — beim Führen festhalten und den Arbeitsbereich frei halten.

## Bedienung in RViz
- Panel **MotionPlanning** → Tab **Planning**: **Planning Group** wählen,
  **Query Goal State** setzen (Marker ziehen oder Joints-Tab), **Plan**,
  dann **Execute**.
- **Execute bewegt den ECHTEN Arm** (wie jede MoveIt-Bedienung) — nur bei
  freiem Arbeitsbereich. Zum reinen Angucken bei **Plan** stehen bleiben.

## Caveats (bitte lesen)
- **Software-GL (llvmpipe)** → RViz funktioniert, ist aber langsam. Für
  Inspektion/Planung ok.
- **Geometrie wird gerendert** (UR5, Husky-Basis, Mounts, Sensoren, RealSense via
  apt-`*-description`; Greifer via `rg6_description` aus Source). Fehlt bei einem
  `package://` doch ein Mesh (`Could not load resource ...`), fehlt das jeweilige
  Description-Paket — dann im Dockerfile ergänzen. Kollisionsprüfung/Planung macht
  ohnehin das `move_group` des Roboters.
- **Scaffold, nicht end-to-end hier validiert.** Die exakte Topic-/Frame-/
  Gruppen-Verdrahtung kann je nach Clearpath-Version einmalig anzupassen sein
  (siehe Checks oben).

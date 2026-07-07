# husky-offboard-lite

Schlankes Offboard-Image (ROS 2 Jazzy), das sich **wie die LAN-Variante von
`husky-offboard`** per Zenoh mit dem echten Roboter verbindet — aber **ohne den
Clearpath-Overhead**. Einziger Zweck: **MoveIt in RViz öffnen** und das auf dem
Roboter bereits laufende `move_group` grafisch bedienen (Plan & Execute für den
UR5). RViz läuft im Browser (noVNC).

Inspiriert von `../husky-offboard` (unangetastet), aber bewusst reduziert.

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

## Was drin ist (vs. husky-offboard)
| | husky-offboard (LAN) | **husky-offboard-lite** |
|---|---|---|
| Zenoh-Anbindung an den Roboter | ✅ | ✅ |
| noVNC-Desktop | ✅ | ✅ |
| `clearpath-desktop` / `-simulator` (Gazebo, viz) | ✅ | ❌ |
| Clearpath **`*-description`** (Meshes) | ✅ | ✅ (nur Descriptions) |
| Clearpath-Generatoren + `robot.yaml`-Mount | ✅ | ❌ |
| move_group **im Container** (remote-MoveIt) | ✅ (`cp-moveit`) | ❌ (nutzt das des Roboters) |
| rg6-/UR-Treiber-Build, foxglove | ✅ | ❌ (nur `rg6_description`-Meshes) |
| **RViz + MoveIt-MotionPlanning-Plugin** | ✅ | ✅ |

Installiert werden: `rviz2`, `moveit-ros-visualization`, `moveit-kinematics`,
`rmw-zenoh-cpp`, die `*-description`-Mesh-Pakete (UR5, Husky-Platform, Mounts,
Sensors, Manipulators, RealSense) + `rg6_description` aus Source (Greifer) + der
noVNC-Desktop. → kleiner als der volle `clearpath-desktop`/`-simulator`-Stack.

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
   per `CP_RSP_NODE=/... CP_MG_NODE=/... moveit-rviz` überschreiben.

2. **TF-Namespace.** Clearpath publiziert TF **namespaced** (`/a200_0553/tf`,
   `/a200_0553/tf_static`). `moveit-rviz` remappt `/tf` + `/tf_static` daher
   standardmäßig dorthin — sonst „No tf data" und **kein Planen möglich**.
   Publiziert dein Setup TF doch global, abschalten mit `CP_TF_REMAP=0 moveit-rviz`.
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
- **macOS:** noVNC, weil X11/OpenGL-Forwarding via XQuartz unzuverlässig ist.
  Auf einem **Linux-Host** ginge stattdessen `network_mode: host` + `DISPLAY`/X11
  ohne den noVNC-Umweg (dann `moveit-rviz` direkt gegen `$DISPLAY`).

## Verwandtschaft
`../husky-offboard` bleibt die vollständige Variante (remote-MoveIt im Container,
Gazebo, Twin-Demo). Dieses Image ist die minimale „nur RViz-Ansicht"-Variante,
wenn `move_group` schon auf dem Roboter läuft.

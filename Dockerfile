# Schlankes Offboard-Image (Jazzy): RViz + MoveIt-Motion-Planning-Plugin, um sich
# per Zenoh (wie die LAN-Variante von husky-offboard) mit dem ECHTEN Roboter zu
# verbinden und dort das bereits laufende move_group grafisch zu bedienen.
# KEINE Clearpath-Generatoren, KEIN Gazebo/viz, KEIN move_group im Container.
# Die *-description-Mesh-Pakete sind dabei (zum Rendern der Geometrie), aber
# nicht der ganze clearpath-desktop/-simulator-Stack.
#
# Warum das reicht: Auf dem Roboter ist manipulators.moveit.enable=true ->
# move_group laeuft dort, hat URDF+SRDF als Parameter und bietet die
# move_action-Action. moveit-rviz zieht URDF/SRDF per Parameter-Service vom
# Roboter (die gelatchte Topic wird ueber die Zenoh-Bridge nicht zuverlaessig an
# spaete Subscriber geliefert) und schickt Planungs-Goals an das move_group.
#
# Robot-spezifisches (robot.yaml, SRDF, ...) wird NICHT gebraucht/gemountet ->
# genau das ist der Unterschied zu husky-offboard.
#
# Gemeinsame Layer (Clearpath apt-Repo, GUI/noVNC-Stack, noVNC-Patch,
# rg6_description-Build, start-desktop.sh, ENV-Defaults) liegen im
# husky-offboard-base-Image (siehe ../husky-offboard-base). Default ist das
# GHCR-Image; lokal mit  --build-arg BASE_IMAGE=husky-offboard-base:jazzy
# ueberschreibbar.
ARG BASE_IMAGE=ghcr.io/clairlab-haw/husky-offboard-base:jazzy
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

# --- Das Noetige ----------------------------------------------------------
#  rviz2                          -> der Viewer
#  moveit-ros-visualization       -> das MotionPlanning-RViz-Plugin (Plan/Execute)
#  moveit-kinematics              -> KDL-IK-Plugin (interaktiver Marker/Drag lokal)
#  rmw-zenoh-cpp                  -> gleiche Middleware wie der Roboter
#  *-description                  -> Meshes fuer die package://-URIs des URDF:
#     ur-description                 UR5-Arm
#     clearpath-platform-description Husky-Basis (top_chassis, bumpers, ...)
#     clearpath-mounts-description   Montageplatten
#     clearpath-sensors-description  Sensor-Halter
#     clearpath-manipulators-description  Arm-Anbindung
#     realsense2-description         RealSense-Kamera
#  (rg6_description = Greifer -> bereits aus der Base, /opt/onrobot-rg6)
#  xacro                          -> Build-Dep fuer rg6_description (in der Base gebaut)
# colcon + GUI/noVNC-Stack liegen in der Base; hier nur die Viewer-/MoveIt-Pakete.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-jazzy-rviz2 \
        ros-jazzy-moveit-ros-visualization \
        ros-jazzy-moveit-kinematics \
        ros-jazzy-rmw-zenoh-cpp \
        ros-jazzy-ur-description \
        ros-jazzy-clearpath-platform-description \
        ros-jazzy-clearpath-mounts-description \
        ros-jazzy-clearpath-sensors-description \
        ros-jazzy-clearpath-manipulators-description \
        ros-jazzy-realsense2-description \
        ros-jazzy-xacro \
    && rm -rf /var/lib/apt/lists/*

# --- rg6-Quellen auffrischen + rg6_description neu bauen -------------------
# Der Clone /opt/onrobot-rg6 kommt aus dem Base-Image und ist so alt wie dessen
# git-clone-Layer. Damit ein Rebuild die AKTUELLEN Greifer-Meshes bekommt, wird
# hier auf $RG6_REF nachgezogen und rg6_description neu gebaut (1:1 wie in
# husky-offboard/Dockerfile, dort zusaetzlich rg6_control).
#
# Cache-Buster: BuildKit laedt die URL bei JEDEM Build und vergleicht den Inhalt
# -> die Layer ab hier werden GENAU DANN neu gebaut, wenn sich der Commit von
# $RG6_REF geaendert hat. Ohne das blieben fetch+colcon ewig im Layer-Cache.
# Ohne Netz bzw. bei erschoepftem GitHub-API-Rate-Limit (60/h unauthentifiziert)
# scheitert das ADD und damit der Build — dann die ADD-Zeile temporaer
# auskommentieren (der git fetch unten laeuft weiter, nur eben cache-abhaengig).
# Anderer Branch/Tag/Fork:  docker build --build-arg RG6_REF=<ref>
ARG RG6_REPO=CLAIRLab-HAW/onrobot-rg6
ARG RG6_REF=main
ADD https://api.github.com/repos/${RG6_REPO}/commits/${RG6_REF} /tmp/rg6-commit.json
# build/install/log werden vorher weggeworfen: nach einem `reset --hard` koennen
# im Base-Image gebaute Artefakte zu geloeschten/umbenannten Quellen gehoeren,
# die colcon inkrementell nicht aufraeumt (Stale-Meshes).
# Anders als in der Base wird ein Fehler hier NICHT zu WARN degradiert: lite hat
# keine rg6-Selbstheilung im entrypoint.sh (vgl. husky-offboard), ein leeres
# install/ faellt erst als unsichtbarer Greifer in RViz auf.
RUN source /opt/ros/jazzy/setup.bash \
    && cd /opt/onrobot-rg6 \
    && git fetch --prune origin "$RG6_REF" \
    && git reset --hard FETCH_HEAD \
    && echo "[rg6] $(git log -1 --format='%h %ci %s')" \
    && rm -rf build install log /tmp/rg6-commit.json \
    && colcon build --packages-select rg6_description \
    || { echo "ERROR: rg6_description-Fetch/Build fehlgeschlagen -> Greifer bleibt ohne Mesh. Build-Log pruefen."; exit 1; }

# --- RViz-Config + Kinematik + Helferskripte -------------------------------
COPY config/ /opt/moveit_rviz/
COPY scripts/moveit-rviz /usr/local/bin/moveit-rviz
COPY scripts/teach-pose /usr/local/bin/teach-pose
COPY scripts/teach_pose.py /opt/teach_pose/teach_pose.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/moveit-rviz /usr/local/bin/teach-pose

# RMW/DOMAIN/LIBGL/DISPLAY/CLEARPATH_NS/NOVNC_* erben aus der Base; Compose kann
# sie ueberschreiben. Kein offboard-spezifisches CLEARPATH_SETUP hier.

# 6080 = noVNC (Browser), 5900 = rohes VNC von x11vnc (nativer Viewer).
EXPOSE 6080 5900

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
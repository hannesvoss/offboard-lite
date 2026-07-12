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
FROM ros:jazzy-ros-base

SHELL ["/bin/bash", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG RG6_REPO_URL=https://github.com/CLAIRLab-HAW/onrobot-rg6.git

# --- Clearpath apt-Repo (nur fuer die Description-/Mesh-Pakete) -------------
# Bewusst NICHT clearpath-desktop/-simulator (Gazebo, viz, Generatoren) -> nur
# die *-description-Pakete unten. Repo-Setup wie im husky-offboard Dockerfile.
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget gnupg lsb-release ca-certificates git \
    && mkdir -p /etc/apt/keyrings \
    && wget -qO - https://packages.clearpathrobotics.com/public.key \
        | gpg --dearmor -o /etc/apt/keyrings/clearpath.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/clearpath.gpg] https://packages.clearpathrobotics.com/stable/ubuntu $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/clearpath-latest.list \
    && rm -rf /var/lib/apt/lists/*

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
#  (rg6_description = Greifer -> aus Source, kein apt-Paket, siehe unten)
#  xacro                          -> Build-Dep fuer rg6_description
#  colcon                         -> rg6_description bauen
# GUI: Xvfb + x11vnc + noVNC + fluxbox + Software-GL (llvmpipe) -> RViz im Browser
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
        python3-colcon-common-extensions \
        xvfb x11vnc novnc websockify fluxbox xterm \
        mesa-utils libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*

# --- noVNC per Default mit lokalem Scaling ---------------------------------
# noVNC liest den Resize-Modus aus dem URL-Parameter ?resize= (Werte: off/scale/
# remote); ohne Parameter defaultet ui.js auf 'off' -> der Framebuffer wird 1:1
# im Browser-Fenster gezeigt und bei kleinerem Viewport beschnitten. Wir setzen
# den Default in app/ui.js ('off' -> 'scale'), sodass der Framebuffer lokal an
# die Browser-Fenstergroesse skaliert wird, sobald man die Seite oeffnet. URL
# (?resize=off|remote) und der Cookie-Override (Settings-Panel) haben weiter
# Vorrang -> ein mal umgestellter User behaelt seine Wahl. Identisch zum
# husky-offboard-Image.
RUN sed -i "s/UI\.initSetting('resize', 'off')/UI.initSetting('resize', 'scale')/" \
        /usr/share/novnc/app/ui.js \
    && grep -q "UI.initSetting('resize', 'scale')" /usr/share/novnc/app/ui.js \
    && echo "[novnc] resize-Default -> scale (lokales Scaling)"

# --- rg6_description (Greifer-Meshes) aus Source ---------------------------
# Kein apt-Paket. Nur rg6_description (Meshes) noetig, NICHT rg6_control (Treiber)
# -> leichter als in husky-offboard. Aufloesung erfolgt spaeter per package://
# (Overlay wird in entrypoint.sh + moveit-rviz gesourct).
RUN git clone "$RG6_REPO_URL" /opt/onrobot-rg6 \
    && source /opt/ros/jazzy/setup.bash \
    && cd /opt/onrobot-rg6 \
    && colcon build --packages-select rg6_description \
    || echo "WARN: rg6_description-Build fehlgeschlagen -> Greifer bleibt ohne Mesh."

# --- RViz-Config + Kinematik + Helferskripte -------------------------------
COPY config/ /opt/moveit_rviz/
COPY scripts/moveit-rviz /usr/local/bin/moveit-rviz
COPY scripts/teach-pose /usr/local/bin/teach-pose
COPY scripts/teach_pose.py /opt/teach_pose/teach_pose.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/moveit-rviz /usr/local/bin/teach-pose

ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp \
    ROS_DOMAIN_ID=0 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    DISPLAY=:1 \
    CLEARPATH_NS=a200_0553 \
    NOVNC_WIDTH=1600 \
    NOVNC_HEIGHT=900

EXPOSE 6080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]

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

# --- rg6_description (Greifer-Meshes) aus Source ---------------------------
# Kein apt-Paket. Nur rg6_description (Meshes) noetig, NICHT rg6_control (Treiber)
# -> leichter als in husky-offboard. Aufloesung erfolgt spaeter per package://
# (Overlay wird in entrypoint.sh + moveit-rviz gesourct).
RUN git clone "$RG6_REPO_URL" /opt/onrobot-rg6 \
    && source /opt/ros/jazzy/setup.bash \
    && cd /opt/onrobot-rg6 \
    && colcon build --packages-select rg6_description \
    || echo "WARN: rg6_description-Build fehlgeschlagen -> Greifer bleibt ohne Mesh."

# --- RViz-Config + Kinematik + Helferskript --------------------------------
COPY config/ /opt/moveit_rviz/
COPY moveit-rviz /usr/local/bin/moveit-rviz
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/moveit-rviz

ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp \
    ROS_DOMAIN_ID=0 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    DISPLAY=:1 \
    CLEARPATH_NS=a200_0553

EXPOSE 6080

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]

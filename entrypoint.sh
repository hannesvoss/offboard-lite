#!/usr/bin/env bash
# Schlanker Offboard-Entrypoint:
#   1) ROS sourcen
#   2) lokalen Zenoh-Router starten (verbindet zum Roboter-Router, wie LAN-Variante)
#   3) noVNC-Desktop starten (RViz im Browser)
#   4) CMD ausfuehren (Default: sleep infinity -> Container bleibt offen)
#
# Unterschied zu husky-offboard/entrypoint.sh: KEINE Clearpath-Generatoren,
# KEINE robot.yaml. Das Modell kommt live vom move_group des Roboters.
set -uo pipefail

src() { set +u; # ROS-setup-Skripte vertragen kein nounset
  # shellcheck disable=SC1090
  source "$1" 2>/dev/null || true; set -u; }

src /opt/ros/jazzy/setup.bash
# rg6_description-Overlay (Greifer-Meshes) -> package://rg6_description aufloesbar
[ -f /opt/onrobot-rg6/install/setup.bash ] && src /opt/onrobot-rg6/install/setup.bash
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# --- Zenoh-Router (verbindet zum Roboter) ----------------------------------
# Zwei Betriebsarten:
#  - OFFBOARD (Mac/LAN): ein lokaler rmw_zenohd verbindet sich zum Zenoh-Router
#    des Roboters (ROBOT_ZENOH_ENDPOINT) -> Container joint dessen ROS-Graphen.
#  - AUF DEM ROBOTER (ZENOH_LOCAL=1, network_mode: host): KEIN eigener Router.
#    Der rmw_zenoh-Client (RViz) verbindet sich per Default mit dem bereits
#    laufenden Router des Roboters auf localhost:7447. Ein zweiter Router wuerde
#    dort nur mit Port 7447 kollidieren.
if [ "${RMW_IMPLEMENTATION}" != "rmw_zenoh_cpp" ]; then
    echo "[lite] RMW=${RMW_IMPLEMENTATION} (kein Zenoh) -> kein Router."
elif [ "${ZENOH_LOCAL:-0}" = "1" ]; then
    echo "[lite] nutze robot-lokalen Zenoh-Router (localhost:7447) -> kein eigener Router."
elif [ -n "${ROBOT_ZENOH_ENDPOINT:-}" ]; then
    cat > /tmp/router_config.json5 <<EOF
{ mode: "router", connect: { endpoints: ["${ROBOT_ZENOH_ENDPOINT}"] } }
EOF
    export ZENOH_ROUTER_CONFIG_URI=/tmp/router_config.json5
    echo "[lite] starte rmw_zenohd -> ${ROBOT_ZENOH_ENDPOINT}"
    ros2 run rmw_zenoh_cpp rmw_zenohd >/tmp/zenohd.log 2>&1 &
    sleep 3
else
    echo "[lite] WARN: ROBOT_ZENOH_ENDPOINT nicht gesetzt -> keine Verbindung zum Roboter."
fi

# --- noVNC-Desktop ---------------------------------------------------------
export DISPLAY="${DISPLAY:-:1}"
# NOVNC_WIDTH/NOVNC_HEIGHT (ENV im Dockerfile) sind die einzige Quelle fuer die
# Desktop-Aufloesung. Die RViz-Config (config/moveit.rviz, Window Geometry
# 1600x880 @0,0) ist auf diesen Default abgestimmt (Height -20 fuer die
# Fluxbox-Titelleiste) -> kein Beschnitt im Browser. noVNC defaultet auf lokales
# Scaling (s. Dockerfile).
export NOVNC_WIDTH="${NOVNC_WIDTH:-1600}"
export NOVNC_HEIGHT="${NOVNC_HEIGHT:-900}"
echo "[lite] starte virtuellen Desktop auf ${DISPLAY} (noVNC :6080, ${NOVNC_WIDTH}x${NOVNC_HEIGHT})"
Xvfb "${DISPLAY}" -screen 0 "${NOVNC_WIDTH}x${NOVNC_HEIGHT}x24" -ac >/tmp/xvfb.log 2>&1 &
sleep 1
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display "${DISPLAY}" -nopw -forever -shared -rfbport 5900 -bg -quiet \
    >/tmp/x11vnc.log 2>&1 || true
websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/novnc.log 2>&1 &
echo "[lite] Desktop bereit: http://localhost:6080/vnc.html"

echo "[lite] bereit. Im noVNC-Terminal: moveit-rviz  |  teach-pose (Posen per FreeDrive)"
exec "$@"

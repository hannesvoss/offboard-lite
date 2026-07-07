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
# Wie docker-compose.lan.yml von husky-offboard: ein lokaler rmw_zenohd
# verbindet sich zum Zenoh-Router des Roboters (ROBOT_ZENOH_ENDPOINT), dadurch
# joint der Container dessen ROS-Graphen.
if [ "${RMW_IMPLEMENTATION}" != "rmw_zenoh_cpp" ]; then
    echo "[lite] RMW=${RMW_IMPLEMENTATION} (kein Zenoh) -> kein Router."
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
echo "[lite] starte virtuellen Desktop auf ${DISPLAY} (noVNC :6080)"
Xvfb "${DISPLAY}" -screen 0 1600x900x24 -ac >/tmp/xvfb.log 2>&1 &
sleep 1
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display "${DISPLAY}" -nopw -forever -shared -rfbport 5900 -bg -quiet \
    >/tmp/x11vnc.log 2>&1 || true
websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/novnc.log 2>&1 &
echo "[lite] Desktop bereit: http://localhost:6080/vnc.html"

echo "[lite] bereit. Im noVNC-Terminal: moveit-rviz"
exec "$@"

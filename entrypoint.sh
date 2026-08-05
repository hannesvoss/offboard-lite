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

if [ -r /usr/local/bin/clearlog.sh ]; then
    . /usr/local/bin/clearlog.sh
else
    log_debug() { :; }
    # shellcheck disable=SC2059
    log_info()  { if [ "$#" -gt 1 ]; then printf "$@" >&2; else printf '%s' "${1:-}" >&2; fi; echo >&2; }
    log_warn()  { log_info "$@"; }
    log_error() { log_info "$@"; }
    log_phase() { log_info "$@"; }
    clearlog_name() { :; }
fi
clearlog_name lite.entry

src() { set +u; # ROS-setup-Skripte vertragen kein nounset
  # shellcheck disable=SC1090
  source "$1" 2>/dev/null || true; set -u; }

src /opt/ros/jazzy/setup.bash
# rg6_description-Overlay (Greifer-Meshes) -> package://rg6_description aufloesbar
[ -f /opt/onrobot-rg6/install/setup.bash ] && src /opt/onrobot-rg6/install/setup.bash
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_zenoh_cpp}"
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"

# --- Zenoh-Router (verbindet zum Roboter) ----------------------------------
# Die Router-Logik (RMW-Check, ZENOH_LOCAL=1 auf dem Roboter,
# ROBOT_ZENOH_ENDPOINT offboard) liegt EINMAL im Base-Image:
# /usr/local/bin/zenoh-connect.sh (husky-offboard-base/scripts/).
zenoh-connect.sh lite

# --- noVNC-Desktop ---------------------------------------------------------
# Gemeinsamer Desktop-Start (Xvfb/fluxbox/x11vnc/websockify) liegt im
# husky-offboard-base-Image als /usr/local/bin/start-desktop.sh; nimmt
# DISPLAY/NOVNC_WIDTH/NOVNC_HEIGHT aus dem Environment (Base-ENV-Defaults).
# Die RViz-Config (config/moveit.rviz, Window Geometry 1600x880 @0,0) ist auf
# diesen Default abgestimmt (Height -20 fuer die Fluxbox-Titelleiste) -> kein
# Beschnitt im Browser. noVNC defaultet auf lokales Scaling (s. Base-Dockerfile).
start-desktop.sh lite

echo "bereit. Im noVNC-Terminal: moveit-rviz  |  teach-pose (Posen per FreeDrive)"
exec "$@"

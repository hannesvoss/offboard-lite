# husky-offboard-lite

Lean offboard image (ROS 2 Jazzy) that connects to the Husky via Zenoh.
Its sole purpose: **open MoveIt in RViz** and graphically operate the
`move_group` already running on the robot (Plan & Execute for the
UR5). RViz runs in the browser (noVNC).

## Features

- **RViz + MoveIt against the robot's own `move_group`** — no second planning
  stack, no Clearpath bringup in the container.
- **Slim**: only what a viewing and teaching client needs.
- **`teach-pose`** writes poses straight into the `robot.yaml` shape.
- **RViz starts by itself** — `command: moveit-rviz` in the base compose, so
  `docker compose up -d` is the whole ritual; no xterm click-through.
- **Two ways to watch**: noVNC in the browser (`:6080`) *or* a native VNC
  viewer straight on `:5900` (no browser, no websockify in the path).

## Tech Stack

Docker (arm64 native), ROS 2 Jazzy, RViz2, MoveIt, Zenoh. Built `FROM`
[husky-offboard-base](../husky-offboard-base/README.md).

### Base image
This image builds on the shared [`husky-offboard-base`](https://github.com/CLAIRLab-HAW/husky-offboard-base)
(Clearpath apt repo, noVNC/desktop stack, noVNC scaling patch,
`rg6_description` build, `/usr/local/bin/start-desktop.sh`, shared ENV defaults).
In the Dockerfile:
```dockerfile
ARG BASE_IMAGE=ghcr.io/clairlab-haw/husky-offboard-base:jazzy
FROM ${BASE_IMAGE}
```
The default is the **GHCR image** (a base build, cached everywhere). For a
local build without a registry pull, build the base yourself first
(`../husky-offboard-base`) and override `BASE_IMAGE`:
```bash
docker compose build \
  --build-arg BASE_IMAGE=husky-offboard-base:jazzy
# or:  export BASE_IMAGE=husky-offboard-base:jazzy  (compose default takes effect)
```
For reproducible builds, pin the base digest (`FROM ...@sha256:...`).

This container's `docker logs` follows the same scheme as the rest of the
workspace (same columns for shell, ROS and Python) — details in
[docs/handbook/06-protokollierung.md](../../docs/handbook/06-protokollierung.md),
not repeated here. One thing worth knowing locally: `moveit-rviz` sources
`/usr/local/bin/clearlog.sh` when the base image carries it, and otherwise
defines plain-`echo` stand-ins for `log_info` and friends (the `if [ -r
/usr/local/bin/clearlog.sh ]` block at the top of the script). Either way it
starts — a base without `clearlog.sh` costs the formatting, nothing
else. `teach-pose` is unaffected either way — it never
sources `clearlog.sh` and has no `log_*` calls of its own, it just `exec`s
`teach_pose.py` directly (plain `print()` / rclpy's own logger). So this image
is not blocked on the `BASE_IMAGE=husky-offboard-base:jazzy` override the way
`husky-offboard` is (see that image's README for the concrete failure mode).

### Why this works without the Clearpath stack
On the robot, `manipulators.moveit.enable: true` → **`move_group` runs
there** and provides:
- `/a200_0553/robot_description` (URDF, from `robot_state_publisher`)
- `/a200_0553/robot_description_semantic` (SRDF, from `move_group`)
- the `/a200_0553/move_action` action + planning scene topics

The `moveit-rviz` script **pulls URDF + SRDF at startup via the parameter service**
from the robot and passes them to RViz as local parameters. It asks
`move_group` for both (`robot_description` + `robot_description_semantic`) and
falls back to `robot_state_publisher` only for the URDF. `move_group` is asked
first because it is the node that *plans* with the model — what it serves is by
definition the model the goals run against — and because the SRDF exists only
there. The fallback is a precaution against a partial URDF, not a fix for an
observed divergence: in the container mock both sources measure byte-identical.

Planning goals go to the robot's `move_group` (`move_action`). So the
container does **not** need to bring its own `move_group`, **no** Clearpath
generators, **no** `robot.yaml`, and **no** Gazebo.

That cuts both ways for the gripper: the SRDF comes from the robot, so the
`gripper` planning group, its named states and its **collision matrix** are
whatever the robot's `rg6_moveit_patch` wrote — this image has no say in it.
It builds `rg6_description` only, for the meshes. If a gripper pose refuses to
plan here, the place to look is the robot's SRDF, not this container.

> Why the parameter service instead of a live topic: the latched `robot_description`
> string topic is not reliably delivered to late-joining subscribers across the
> Zenoh bridge (RViz saw an empty URDF → `XML_ERROR_EMPTY_DOCUMENT`).
> The parameter service delivers the model already computed on the robot directly.

### What's inside
Feature | **husky-offboard-lite** |
|---|---|
| Zenoh connection to the robot | ✅ |
| noVNC desktop | ✅ |
| `clearpath-desktop` / `-simulator` (Gazebo, viz) | ❌ |
| Clearpath **`*-description`** (meshes) | ✅ (descriptions only) |
| Clearpath generators + `robot.yaml` mount | ❌ |
| move_group **in the container** (remote MoveIt) | ❌ (uses the robot's) |
| rg6/UR driver build, foxglove | ❌ (only `rg6_description` meshes) |
| **RViz + MoveIt MotionPlanning plugin** | ✅ |

Installed: `rviz2`, `moveit-ros-visualization`, `moveit-kinematics`,
`rmw-zenoh-cpp`, the `*-description` mesh packages (UR5, Husky platform, mounts,
sensors, manipulators, RealSense) + `rg6_description` from source (gripper) + the
noVNC desktop.

## Installation

```bash
cd deploy/husky-offboard-lite
BASE_IMAGE=husky-offboard-base:jazzy docker compose build
docker compose up -d
```

## Usage
```bash
# 1) Set ROBOT_ZENOH_ENDPOINT in docker-compose.yml to the robot's
#    LAN IP:Port (port defaults to 7447).
# 2) start -- RViz+MoveIt comes up with the container:
docker compose up -d
# 3a) watch in a native VNC viewer (no noVNC in the path). On macOS the
#     built-in Screen Sharing client handles this:
open vnc://localhost:5900
# 3b) or in the browser, as before:
#     http://localhost:6080/vnc.html
```
The container runs `moveit-rviz` as its `command`: it briefly checks whether
`/a200_0553/move_group` is visible in the graph, then starts RViz with a
preconfigured MotionPlanning panel. Closing the RViz window does **not** kill
the container — it drops back to `sleep infinity`, so you can reopen it from an
xterm on the desktop with `moveit-rviz`, or `docker compose restart`.

**Port 5900 is bound to `127.0.0.1` on purpose.** `x11vnc` runs `-nopw`, i.e.
without a password — a passwordless remote framebuffer has no business on the
LAN. Reaching it from another machine is an SSH tunnel away
(`ssh -L 5900:localhost:5900 <host>`), not a compose edit. Port 6080 keeps its
previous binding (all interfaces).

**This image does not energize the arm.** `moveit-rviz` can reactivate the
arm's trajectory controller, and to do that it calls `ur_state_manager/prepare`
— which puts power on the joints of the **real** robot. `husky-offboard-lite`
is the observer in this setup: it hosts no `move_group`, it does not plan, and
it has no business energizing anything, least of all unattended while a
container boots. `JTC_REACTIVATE` therefore defaults to **`0`** in the script
itself, not just in the compose file, so a hand-typed `moveit-rviz` inside the
container behaves the same way.

Need the reactivation anyway — typically after `husky-demo-imitate`'s graceful
shutdown left the JTC inactive and MoveIt Execute aborts with *"Plan and Execute
request aborted"*? Then say so, for that one run:
```bash
JTC_REACTIVATE=1 moveit-rviz              # inside the container
JTC_REACTIVATE=1 docker compose up -d     # or for the whole container
```

**Gripper meshes stay current on their own.** The build re-fetches
`onrobot-rg6` (`RG6_REF`, default `main`) and rebuilds `rg6_description`; a
cache-busting `ADD` of the GitHub commit API invalidates that layer exactly when
the upstream commit changes — no `--no-cache` needed. Another branch/tag/fork:
`docker compose build --build-arg RG6_REF=<ref>` (`RG6_REPO` likewise). To also
refresh the GHCR base image itself: `docker compose build --pull`.

### Variant: directly on the robot (`docker-compose.robot.yml`)
Instead of offboard from the laptop, the same container can run **on the robot**.
It then shares the network stack via `network_mode: host` and uses the robot's
already-running Zenoh router (`localhost:7447`) — **no** own
`rmw_zenohd`, **no** `ROBOT_ZENOH_ENDPOINT` (`ZENOH_LOCAL=1` handles that).
```bash
# build+start on the robot (native x86_64!):
docker compose -f docker-compose.yml -f docker-compose.robot.yml up --build
# from the laptop browser:
#   http://<robot-ip>:6080/vnc.html  -> xterm -> moveit-rviz
```
The robot override **takes the autostart back out** (`command: sleep infinity`)
for the load reason below — there RViz is started by hand, as before. It does
**not** re-enable `JTC_REACTIVATE`: running on the robot is not a reason for
this image to energize the arm either. With `network_mode: host` there is no
port mapping, so `5900` is reachable directly on the robot's address; that is
the robot's network, and `-nopw` applies there too.
Things to keep in mind:
- **CPU architecture:** build on the **robot** (x86_64). An image built on Apple
  Silicon (arm64) won't run there without `docker buildx --platform linux/amd64`.
- **Host OS doesn't matter:** the container brings Jazzy itself → it also runs on
  the Ubuntu Server 22.04 host without touching it.
- **Load:** RViz renders with software GL (llvmpipe, CPU-hungry) and competes
  with `move_group`/controllers/perception. Start it only when needed (no
  autostart), so the 125 Hz arm control loop doesn't suffer. Over the network,
  VNC pixels travel instead of ROS data.

### One-time wiring checks (important)
Because **nothing is generated** here, everything depends on the robot's live
topics/frames. If the model doesn't appear or the panel stays empty, check in
this order (in the noVNC xterm):

1. **Graph + model parameters visible?** `moveit-rviz` fetches URDF/SRDF via the
   parameter service. Check manually:
   ```bash
   ros2 node list | grep -E 'move_group|robot_state_publisher'   # correct node names?
   # same order the script uses: move_group first, robot_state_publisher only
   # as the URDF fallback
   ros2 param get /a200_0553/move_group robot_description | head -c 120
   ros2 param get /a200_0553/move_group robot_description_semantic | head -c 120
   ros2 param get /a200_0553/robot_state_publisher robot_description | head -c 120
   ```
   Empty/error → Zenoh/network: is `ROBOT_ZENOH_ENDPOINT` correct? Is the robot
   reachable (`ping`)? Is `rmw_zenohd` running (`cat /tmp/zenohd.log`)? If the
   nodes are named differently, override via `RSP_NODE=/... MG_NODE=/... moveit-rviz`.

2. **TF namespace.** Clearpath publishes TF **namespaced** (`/a200_0553/tf`,
   `/a200_0553/tf_static`). `moveit-rviz` therefore remaps `/tf` + `/tf_static`
   there by default — otherwise "No tf data" and **no planning possible**.
   If your setup does publish TF globally, disable it with `TF_REMAP=0 moveit-rviz`.
   If the model stays "without transform", set `Fixed Frame` in RViz to an
   existing frame (e.g. `base_link` or `arm_0_base_link`).

3. **Planning group name** (only for the interactive drag marker). The real name
   is in the SRDF:
   ```bash
   ros2 topic echo /a200_0553/robot_description_semantic --once | grep '<group '
   ```
   If it's not in `config/kinematics.yaml`, add it there as another key (restart
   `moveit-rviz`). Without local IK, MoveIt is still usable: Tab **Joints**,
   **Update**, **Plan** & **Execute**.

### Teaching poses for `robot.yaml` (`teach-pose`)
In the noVNC xterm, alongside `moveit-rviz`, there's the script **`teach-pose`**.
With it you drive the UR5 **via FreeDrive** by hand into a pose and get the joint
angles in the exact YAML format that `husky-custom-setup/robot.yaml` expects under
`manipulators.arms[].poses` — from there they become named **MoveIt group states**
on the next Clearpath generator run (selectable in RViz/MoveIt as a named
position).

```bash
teach-pose                    # FreeDrive on, then teach poses
teach-pose -o /tmp/poses.yaml # also write to a file
teach-pose --no-freedrive     # don't toggle FreeDrive itself
```
Flow at the prompt (`pose>`):
- Move the arm into position by hand, then **type a name** (`home`,
  `pick_ready`, …) → current joint angles are recorded.
- `list` / `del <name>` / `now` (raw values) / `save` (print block) /
  `quit` (or Ctrl-D).
- On exit it **always switches back to `mode/trajectory` (JTC)** so that
  MoveIt Execute works again.

**How FreeDrive is correctly activated** (otherwise the mode manager reports
"active" but the arm stays stiff): `teach-pose` does the same as `husky-demo-imitate`:
1. **`ur_state_manager/prepare`** — power on the arm, **release brakes**, RUNNING +
   ExternalControl. Without ExternalControl running, the FreeDrive URScript
   never reaches the arm → arm doesn't move. (Dismissible with `--no-prepare`.)
2. Activate **`mode/freedrive`** and continuously publish `enable_freedrive_mode=true`
   (`std_msgs/Bool`, ~2 Hz) — the `ur_controllers/FreedriveModeController`
   drops out on its own when no more `true` arrives. `teach-pose` keeps this
   going in a background thread (rate via `--freedrive-rate`).

`teach-pose` reads **`/<ns>/manipulators/joint_states`** (the live arm JSB source;
on a200-0553 the custom-setup moves the arm output there,
`platform/joint_states` is only a relay). The node **spins continuously in the
background** so the values are always fresh when capturing. Joint selection is
**by name** (`arm_0_*`), not by array order. Use another source via
`--joints-topic`. Prerequisite: the arm is powered on (E-Stop released) and the
`arm_controllers.launch.py` stack (incl. `freedrive_mode_controller`) +
`ur_state_manager` are running on the robot (on a200-0553 as a boot service).
Then insert the output under the UR5 arm in `robot.yaml` and regenerate with
`generate_semantic_description` (see below).

**Troubleshooting: all poses come out identical.** Then the arm didn't physically
move (FreeDrive isn't engaging) or a dead source is being read. Test: after
startup type `now`, push the arm by hand, type `now` again — **the numbers must
change**. If they don't:
- Brakes/ExternalControl not active → `prepare` failed (E-Stop released? Arm
  powered? Teach panel "External Control" running?).
- Cross-check in a second xterm which topic is live:
  `ros2 topic echo /<ns>/manipulators/joint_states --field position` vs
  `ros2 topic echo /<ns>/platform/joint_states --field position` (push the arm).

> **Caution:** In FreeDrive the arm may sag slightly under gravity — hold on to
> it while guiding and keep the workspace clear.

### Operating in RViz
- Panel **Motion Planning** → Tab **Planning**: select **Planning Group**, set
  **Query Goal State** (drag the marker or use the Joints tab), **Plan**,
  then **Execute**.
- **Execute moves the REAL arm** (as does any MoveIt operation) — only with a
  clear workspace. To just look, stop at **Plan**.

## Caveats (please read)
- **Software GL (llvmpipe)** → RViz works but is slow. Fine for
  inspection/planning.
- **Geometry is rendered** (UR5, Husky base, mounts, sensors, RealSense via
  apt-`*-description`; gripper via `rg6_description` from source). If a mesh is
  still missing for a `package://` (`Could not load resource ...`), the respective
  description package is missing — add it in the Dockerfile. Collision
  checking/planning is done by the robot's `move_group` anyway.
- **Scaffold, not end-to-end validated here.** The exact topic/frame/group wiring
  may need a one-time adjustment depending on the Clearpath version (see the
  checks above).

## Related

- [husky-offboard](../husky-offboard/README.md) — the full offboard container
- [husky-offboard-base](../husky-offboard-base/README.md) — the shared base

## Versioning

[Semantic Versioning](https://semver.org/) via the `VERSION` file and
[CHANGELOG.md](CHANGELOG.md).

## License

See workspace root.

# carv_ws

The ROS2 half of LaunchSpot: one image, one compose project, one colcon workspace.

`spot_ros2:latest` is **pre-built**. It is `docker load`ed from the untracked 1.2 GB
`spot_ros2_arm64.tgz` in this directory, and **nothing here can rebuild it** — that workspace is
already built inside the image at `/ros_ws`. Everything here layers `carv:latest` on top of it.

What a package under `src/` *does* belongs to that package: see `src/reflect_id/CLAUDE.md` and
`src/punch_bot/CLAUDE.md`.

**Everything in this file is relative to `carv_ws`.** Do not write paths that reach outside it, and
do not write `~/carv_ws` — this workspace is not tied to a home directory and may be checked out
anywhere.

## Files

| Path | Role |
|---|---|
| `Dockerfile` | `FROM spot_ros2:latest` + apt packages + the two `scripts/` files + the `src/` build. Builds `carv:latest`, which every service here runs |
| `docker-compose.yaml` | The `ros2` project. Pins `name: ros2`. Run from in here; every path in it is relative to this directory |
| `scripts/spot-launch` | `wrapper`'s main process. Reads `/spot-config/launch.yaml` and builds the `ros2 launch` argv. Nothing else uses it |
| `scripts/entrypoint.sh` | Sources ROS and `exec "$@"`. `COPY`d to `/ros_entrypoint.sh`; the base image has none |
| `scripts/create_ros_package.sh` | Host-side scaffolder: runs `ros2 pkg create` in a throwaway container and lands the package in `carv_ws/`. Never `COPY`d into an image |
| `src/` | The colcon workspace's source tree, `COPY`d in and built to `/carv_ws/install`. Both `reflect_id` (`CARV-Lab/reflect_id`) and `punch_bot` (`CARV-Lab/punch_bot`) are **git submodules**, so a clone needs `--recurse-submodules` |
| `config/` | `launch.yaml`, `spot_config.yaml` and the untracked `robot.env`, bind-mounted read-only into `wrapper` at `/spot-config` |
| `spot_ros2_arm64.tgz` | The archived base image, 1.2 GB, **untracked**, excluded from the build context |
| `.dockerignore` | Default-deny allowlist — see "The build context" |

## Services

All `network_mode: host`, which is what puts them on one network for DDS discovery, and all
`ipc: host`, which shares `/dev/shm` so the shared-memory transport between them works.

| Service | Command |
|---|---|
| `wrapper` | `spot-launch`, which execs `ros2 launch spot_driver spot_driver.launch.py` against the real robot |
| `foxglove` | the `foxglove_bridge` node on **21000**, pinned with `-p port:=21000`. The node's compiled default is 21000 but the package's launch file defaults to 8765, so it is set explicitly |
| `reflect_id` | `ros2 launch reflect_id reflect_id.launch.py`. Brings up its own `velodyne_driver_node` — read the Velodyne entry under "Known issues" before starting it |
| `slam` | `ros2 launch punch_bot slam.launch.py` — 2D SLAM off `/velodyne_points`, with `mode` and `map_name` spelled out as launch arguments. See "SLAM" below |
| `velodyne` | `ros2 launch reflect_id velodyne.launch.py` — the sensor half of `reflect_id` alone: the `body -> velodyne` static transform, `velodyne_driver_node` and `velodyne_transform_node`, and nothing that tracks or follows. Not profile-gated, so a bare `up -d` starts it |

**`velodyne` and `reflect_id` must never run together**: `reflect_id.launch.py` includes
`velodyne.launch.py` unconditionally, so both bind UDP 2368 and the second one to start fails — same
conflict as the `velodyne_service` host unit under "Known issues", and the same fix, stop one before
starting the other. `slam` starts neither and needs one of them already up.

A fifth service, `benchmark`, is **commented out** in the compose file. While it stays that way
`docker-compose --profile benchmark up -d benchmark` answers `no such service` — uncomment it
first.

**None of these carries a `restart:` policy.** A crash or a daemon restart leaves them down, and a
reboot leaves them `absent` rather than `stopped`, because a boot-time `docker image prune -f`
removes the stopped containers. Recreate with `docker-compose up -d`.

21000 sits inside Spot's blanket-forwarded TCP range 21000-22000.

They are separate **services** rather than one process for per-process restart: restarting the driver
to pick up a config change does not drop live Foxglove connections. All declare the same `build:`,
because a service with an `image:` and no `build:` makes compose **pull** when the image is absent,
and `carv:latest` exists in no registry.


### Why one image and not two

They were once split, with the bridge on a slim `ros:humble-ros-base`, reasoning that it only needs
DDS discovery. **That reasoning was wrong and the split is not to be reinstated on it.** The bridge
also resolves each type's *schema* through `ament_index`; on the slim image the measured result was
**48 of 59 services** and 12 topics silently dropped — every Spot-specific interface, including
`/dock`, `/robot_command`, `/graph_nav_*` and the whole `/status/*` tree.

Those definitions exist nowhere else: `spot_msgs` is workspace-built at `/ros_ws/install/spot_msgs`
and was never released as a deb, and `bosdyn_*_msgs` are dpkg packages from a repo no longer in the
image's `sources.list` (the official ROS index carries **zero** packages matching `spot` or
`bosdyn`). So the bridge must be built on `spot_ros2:latest`; once it is, running the driver on
anything else buys nothing. Layers are shared, so the extra services cost only the added packages.

## The image

Two points in the Dockerfile's layer order are deliberate.

**`colcon build` runs from `/carv_ws`, never from `src/`.** colcon writes `build/`, `install/` and
`log/` into its working directory, so building from `src/` buries the install space at
`/carv_ws/src/install` — a path nothing sources — and drops three build directories into the source
tree. Both `/opt/ros/humble` and `/ros_ws/install` are sourced for the build, so a package in `src/`
that depends on `spot_msgs` resolves.

**The `BASH_ENV` block comes after the build.** `BASH_ENV` makes every non-interactive bash read
`/etc/ros_setup.sh`, which sources `/carv_ws/install`; setting it earlier makes the colcon `RUN`
itself print `No such file or directory` for a file it is about to create.

**Nothing under `src/` is bind-mounted.** Sources are baked in by `COPY src src`, so a host edit has
no effect until a rebuild. `--symlink-install` links the install space to `/carv_ws/src` *inside the
image*, not to the host — it does not make host edits live.

`--build` rebuilds `carv:latest`, which bounces **every** service in this project, the driver
included, not only the thing that changed.

## Sourcing ROS

`spot_ros2:latest` has **no entrypoint and does not source ROS**. `carv:latest` supplies the one it
lacks (`scripts/entrypoint.sh` → `/ros_entrypoint.sh`), sourcing **three** layers innermost-last —
`/opt/ros/humble`, the base image's prebuilt `/ros_ws/install`, then `/carv_ws/install`, the
workspace this image builds from `src/` — and then `exec "$@"`. That covers the **main process**, so
every compose `command:` is a plain argv list with no `bash -c`.

**Those three lines exist twice and must stay in step**: in `scripts/entrypoint.sh` for the main
process, and in the `/etc/ros_setup.sh` the Dockerfile writes for `docker exec`. Drop
`/carv_ws/install` from either and the workspace packages are still built but invisible in that path
— `ros2 launch reflect_id …` answers `Package 'reflect_id' not found`, with the build logged as
successful.

`docker exec` **bypasses the entrypoint**, so the Dockerfile covers it separately: `/etc/bash.bashrc`
for interactive shells, `ENV BASH_ENV=/etc/ros_setup.sh` for non-interactive ones. Both go through
bash:

```bash
docker exec -it wrapper bash                                 # interactive: bash.bashrc
docker exec foxglove bash -c 'ros2 node list --spin-time 5'  # non-interactive: BASH_ENV
```

`docker exec <c> ros2 ...` with **no** `bash -c` still fails — no shell reads either hook.

## The build context

`.dockerignore` is a **default-deny allowlist** — `*`, then `!Dockerfile !scripts !src`, then
`src/punch_bot/maps` and `**/__pycache__` — because the 1.2 GB archive sits beside the Dockerfile.
Three things about it are load-bearing.

**`!scripts` and `!src` must stay whole directories.** The Dockerfile `COPY`s from inside both, so
naming the files bare leaves them out of the context and the build fails on
`COPY scripts/spot-launch: not found`.

**There is deliberately no `.git` rule, and the reason is that both packages are submodules.** A
submodule's `.git` is a 41-byte *file* pointing at the real gitdir, not a directory, so nothing
leaks. If either is ever replaced by a plain clone that changes completely — the whole history would
enter the context — and the rule to add is `**/.git`, never bare `.git`: Docker matches a pattern
with no `/` against the whole relative path and it never crosses a separator, so a bare `.git` would
not exclude `src/reflect_id/.git`. It would also have to come after `!src` to re-exclude what that
re-included.

**`!src` re-includes whole repositories, not just ROS packages, so non-package directories inside
them must be named back out.** Both packages are checkouts of their own, so anything large dropped
anywhere in one lands in this context. `src/punch_bot/maps` is named back out for exactly that
reason: it holds the floor plan and every SLAM map, which no build step and no running service reads
out of the image — they arrive at runtime on a bind mount instead. **Measured, that one line took
the context from 4.2 MB to 21.7 kB.**

The pattern goes **after** `!src`, because it has to re-exclude what `!src` re-included. A pattern
containing a `/` matches against the whole relative path, so it excludes the directory *and* its
contents (measured) — unlike a bare name, which never crosses a separator.

## The compose project

**The project name is pinned to `ros2`, and the pin is load-bearing.** Compose would otherwise derive
it from the directory basename, `carv_ws`, and anything outside this workspace that addresses these
containers by project name would stop finding them — silently, not loudly.

**Run compose from in here.** Compose resolves a relative bind source like `./config` against the
**project directory**, not against the compose file's own location, and hands the result to the
daemon as a host path. Driving this file with `-f` from a parent directory resolves them against the
wrong place, and `restart wrapper` answers `no such service: wrapper`.

```bash
docker-compose up -d --build     # build carv:latest and start everything
docker-compose restart wrapper   # apply a spot_config.yaml or launch.yaml change
docker-compose logs -f wrapper   # follow the driver
```

## Launch arguments

They live in **`config/launch.yaml`**; the compose `command:` is `["spot-launch"]`. At container
start `spot-launch` reads `/spot-config/launch.yaml`, turns every key into one `key:=value` argument,
and prints the full argv before the `exec` — so `docker logs wrapper | head` answers "what was it
launched with?" without reasoning about files.

Reading them **inside** the container is the point. Compose read `.env` on the *host* at `up` time and
froze the result into `Config.Cmd`, so `restart` re-ran the old argv and only re-creation could apply
a change. Three things are load-bearing:

- **A change needs `docker-compose restart wrapper`, not `up -d`.** Only a change to `spot-launch`
  itself needs `--build`.
- **`spot-launch` knows nothing about defaults** — it passes every key it finds, verbatim. A key
  absent from the file is simply not passed, so the launch file's own default applies.
- **The fallback is the safety net and the one duplicated default.** If `launch.yaml` is missing or
  unreadable, `spot-launch` falls back to the four values `.env` used to hold rather than launching
  bare — upstream `launch_image_publishers` defaults to `True`, and an empty `config_file` means no
  config file at all, silently discarding the passive control posture.

## The config mount

`config/` is mounted **read-only as a directory** at `/spot-config` in `wrapper`. Mounting the
directory rather than the single file is deliberate: a file bind whose source is missing makes Docker
create a *directory* at the destination, which the driver fails on obscurely.

`/spot-config` is the only host directory mounted into `wrapper`, so no other `config_file` path can
exist. **Anything outside this workspace that writes these files pins the same `/spot-config` path,
so moving the mount means changing both ends together.**

`config/robot.env` arrives separately as `env_file:`. `spot_driver` reads `SPOT_IP`,
`BOSDYN_CLIENT_USERNAME` and `BOSDYN_CLIENT_PASSWORD` from the environment **in preference to** the
matching parameters (`spot_ros2.py:492-498`, `rclcpp_parameter_interface.cpp:11-15` inside the
image). That precedence is the single reason `spot_config.yaml` can be tracked. A credential change
needs `up -d` rather than `restart`, since environment is fixed at container creation.

Both YAMLs are read at **node startup**, so an edit to either needs `docker-compose restart wrapper`.
Each carries a generated header naming what wrote it.

## SLAM

The `slam` service runs `punch_bot`'s `slam.launch.py`, which builds a 2D occupancy map from the
Velodyne. The launch file and its parameters belong to that package — `src/punch_bot/CLAUDE.md`,
"2D SLAM", is the reference. What is this directory's business:

```
/velodyne_points  ->  pointcloud_to_laserscan  ->  /scan  ->  slam_toolbox  ->  /map + map->odom
```

```bash
docker-compose up -d slam        # runs whatever mode the compose command names
docker-compose logs -f slam
```

- **`velodyne` (or `reflect_id`) has to be up first.** `slam` starts no driver of its own and only
  subscribes to `/velodyne_points`, deliberately: a second `velodyne_driver_node` would bind UDP
  2368 and fail.
- **`mode` and `map_name` are plain launch arguments, written out in the compose `command:`**, the
  same way `foxglove` pins its port — so the whole invocation reads out of the file with nothing
  supplied by the invoking shell. Changing either means editing the command and running `up -d`;
  a `restart` would re-run the old argv, since compose freezes the command into `Config.Cmd` at
  container creation. For a one-off without editing, pass the arguments to `docker-compose run`.
- **`src/punch_bot/maps` is the one read-write mount in this project**, bound at `/maps`. The maps
  live with the package that produces them and are tracked in its git history; `.dockerignore`
  names that directory back out after `!src`, so they never enter the image and the build context
  stays at tens of KB. **A pose graph is 18 MB on disk but 99.8% zero bytes and gzips to ~35 kB**,
  which is what git actually stores, so tracking them is cheap.
- **One directory per map**, named for the map, with the files inside named for it too —
  `/maps/<name>/<name>.posegraph` and so on. `new` mode creates the directory itself.
  **Never use `gorrie` as a map name**: that directory holds the hand-made floor plan, and saving
  over it would overwrite `gorrie.pgm` and `gorrie.yaml`.
- Maps are written by a root container into a git working tree, so they land `root:root`.
  `git add` and `git commit` work on them; removing or reverting one from the host needs `sudo`.
- **Nothing saves automatically.** Killing the container loses the session. `serialize_map` writes
  the `.posegraph`/`.data` pair that `continue` and `localize` load; `map_saver_cli` writes the
  `.pgm`/`.yaml` that `map_server` loads. They are not interchangeable, and the
  `/slam_toolbox/save_map` service is unreliable here — details in `src/punch_bot/CLAUDE.md`.
- **`slam` and a `map_server` must not run together** — both publish `/map`.
- `slam_toolbox` and `pointcloud_to_laserscan` are installed by this `Dockerfile`. `nav2_map_server`
  is not: it comes from `spot_ros2:latest`, which is also why `map_saver_cli` works without one.

## Nodes

`spot_driver.launch.py` starts six processes in the `wrapper` container:

| Node | Notes |
|---|---|
| `/spot_ros2` | Main driver — leases, e-stop, command dispatch to the BD SDK |
| `/state_publisher` | Joint states, TF, battery/power/fault status topics |
| `/robot_state_publisher` | URDF → TF tree (`base_link`, `body`, per-leg segments) |
| `/kinematic_service` | Inverse kinematics service |
| `/object_sync` | Object synchroniser (world objects ↔ ROS) |
| `/spot_alerts` | Fault popups. Survives while there are no faults; dies when it tries to show one |

Plus `/foxglove_bridge` in the `foxglove` container. Seeing it in `ros2 node list` from inside
`wrapper` is the check that the containers still share a DDS domain.

Current flags from `config/launch.yaml`: `controllable:=False`, `launch_rviz:=False` (headless
host) and `launch_image_publishers:=False` (cameras off — turning it on adds `/image_publisher` and
five `register_node_*` nodes, at CPU cost). `controllable:=False` is what keeps this driver passive:
turning it on claims Spot's lease, which is exclusive, so the tablet loses the robot.

## Known issues

- **`SPOT_PORT=0` in the environment breaks the C++ nodes.** The two driver implementations disagree
  about a present-but-empty sentinel: `wrapper.py:434` does `if port:`, so the Python node treats 0 as
  unset and keeps the SDK default of 443, while `default_spot_api.cpp:46` does
  `if (port.has_value())`, so `SPOT_PORT=0` parses to an *engaged* `optional{0}` and
  `state_publisher`, `kinematic_service` and `object_sync` dial port 0 and die with
  `UnableToConnectToRobotError` — while `/spot_ros2` itself starts cleanly and reports success. The
  symptom is three dead nodes and a healthy-looking main one. **So do not add `SPOT_PORT` to
  `robot.env`** — a stock robot needs neither it nor `SPOT_CERTIFICATE`, and an absent variable is the
  only thing both implementations agree on.
- **`use_velodyne` is a DRIVER setting and has nothing to do with the ROS velodyne packages.** It is
  implemented entirely inside the driver (`spot_ros2.py:459-465` registers a `lidar_points` callback
  on the BD SDK and publishes a plain `sensor_msgs/PointCloud2`), and nothing in
  `spot_driver.launch.py` mentions velodyne. It fails on a robot with no Velodyne physically fitted,
  which is the only real constraint.
- **`velodyne-driver`, `velodyne-pointcloud` and `velodyne-msgs` ARE in `carv:latest`, and
  `reflect_id` is why** — its launch file runs `velodyne_driver_node` and `velodyne_transform_node`
  itself, because it needs the per-return **intensity** that neither the driver's own cloud nor the
  `velodyne_service` host unit exposes. So `reflect_id` and `velodyne_service` both want the same
  physical sensor and are not meant to run together: stop the host unit from `#/home` before starting
  `reflect_id`. (`velodyne_service` was `inactive` and nothing held UDP 2368 when this was checked.)
  Removing these packages to slim the image breaks `reflect_id`'s launch, not the driver.
- **`spot_alerts` dies when a fault occurs, not on every boot.** It builds a tkinter message box only
  when it has an alert to raise, and there is no `$DISPLAY`, so that call throws `TclError`. With
  `faults: []` it runs indefinitely. Useful side effect: a `spot_alerts` crash in the log signals that
  Spot reported a fault. The other five nodes are unaffected.
- `ros2 node list` from a cold `docker exec` often shows a partial list — DDS discovery has not
  finished. Use `--spin-time 5`, not a bug.
- `NotPoweredOnError` in the logs is normal when Spot is connected but motors are off.
- **A viewing machine whose clock differs from Spot's makes TF look frozen.** Spot keeps its own
  system time and it cannot be changed. Every TF and `/joint_states` message is stamped with that
  clock, so a client on a differently-set clock sees stamps far in the past or future: the robot
  description renders but nothing moves. The driver is fine. Fix it on the client. The symptom is a
  static model with live-looking topics and **no error in the logs**.
- **`RMW_IMPLEMENTATION` can no longer disagree between these services** — one image, every
  service on it. It was worth checking first when the bridge ran on its own image; it is not now.

## Gotchas

- **Never `docker rmi spot_ros2:latest`, and never `docker image prune -a`.** **Nothing in this repo
  can rebuild it** — recovery costs a 1.2 GB `docker load` from `spot_ros2_arm64.tgz`. Remove by exact
  tag only: **a bare `docker rmi spot_ros2` resolves to `spot_ros2:latest`**. The rebuildable ROS image
  is deliberately `carv:latest`, a **separate repository name**, so no cleanup of it can ever resolve
  to the irreplaceable one.
- **An untagged `spot_ros2` image does not survive the next reboot.** `load-and-run.sh:22` runs
  `docker image prune -f` on every boot, which removes dangling images. The window between untagging
  and re-tagging is "until the next reboot", with no warning. This is the plain prune, not `-a`, so a
  tagged image is never touched.
- **`rosbag2-storage-mcap` IS installed**, so `ros2 bag record -s mcap` works.

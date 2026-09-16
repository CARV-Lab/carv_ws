#!/bin/bash
# carv:latest is built FROM spot_ros2:latest, which has NO entrypoint and does not source
# ROS, so `ros2` is not on $PATH without this. It runs for the container's MAIN process, which is
# what lets every compose `command:` be a plain argv list with no bash -c sourcing block.
#
# Three layers, innermost last: /opt/ros/humble, then the base image's prebuilt /ros_ws, then
# /carv_ws -- the workspace this image builds from carv_ws/src. Without that third line the
# packages in it are built but invisible, and `ros2 launch reflect_id ...` cannot find them.
#
# It does NOT cover `docker exec` -- exec bypasses the image entrypoint entirely. The Dockerfile
# sets BASH_ENV and /etc/bash.bashrc to handle that case.
set -e
source /opt/ros/humble/setup.bash
source /ros_ws/install/setup.bash
source /carv_ws/install/setup.bash
exec "$@"

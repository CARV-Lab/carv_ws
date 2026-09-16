#!/usr/bin/env bash
# Scaffolds a ROS2 ament_python package using a Docker image, then maps the
# generated files back into this repo (owned by the calling user).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The workspace is the PARENT of this script's directory: a generated package belongs beside
# the Dockerfile in carv_ws/, not in carv_ws/scripts/ alongside the script that made it.
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while true; do
  read -rp "Docker image name: " IMAGE_NAME
  [ -n "$IMAGE_NAME" ] && break
  echo "Docker image name is required."
done

while true; do
  read -rp "ROS package name: " PKG_NAME
  [ -n "$PKG_NAME" ] && break
  echo "ROS package name is required."
done

while true; do
  read -rp "Layout [collapsed | expanded] (default: expanded): " LAYOUT
  LAYOUT="${LAYOUT:-expanded}"
  LAYOUT="$(echo "$LAYOUT" | tr '[:upper:]' '[:lower:]')"
  case "$LAYOUT" in
    c|collapsed) LAYOUT=collapsed; break ;;
    e|expanded) LAYOUT=expanded; break ;;
    *) echo "Please answer 'collapsed'/'c' or 'expanded'/'e'." ;;
  esac
done

while true; do
  read -rp "Delete the generated test/ folder (test_copyright.py, test_flake8.py, test_pep257.py)? [y/n]: " DELETE_TESTS
  DELETE_TESTS="$(echo "$DELETE_TESTS" | tr '[:upper:]' '[:lower:]')"
  case "$DELETE_TESTS" in
    y|yes) DELETE_TESTS=yes; break ;;
    n|no) DELETE_TESTS=no; break ;;
    *) echo "Please answer 'y' or 'n'." ;;
  esac
done

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Error: docker image '$IMAGE_NAME' was not found locally. Build it first (e.g. docker compose build)." >&2
  exit 1
fi

if [ "$LAYOUT" = "expanded" ] && [ -e "$WS_ROOT/$PKG_NAME" ]; then
  echo "Error: $WS_ROOT/$PKG_NAME already exists." >&2
  exit 1
fi

echo
echo "Image:        $IMAGE_NAME"
echo "Package:      $PKG_NAME"
echo "Layout:       $LAYOUT"
echo "Delete tests: $DELETE_TESTS"
echo

if [ "$LAYOUT" = "collapsed" ]; then
  COPY_CMD="cp -rn \"/tmp/gen/$PKG_NAME/.\" /workspace/"
else
  COPY_CMD="cp -r \"/tmp/gen/$PKG_NAME\" \"/workspace/$PKG_NAME\""
fi

if [ "$DELETE_TESTS" = "yes" ]; then
  RM_TESTS_CMD="rm -rf \"/tmp/gen/$PKG_NAME/test\""
else
  RM_TESTS_CMD=":"
fi

docker run --rm \
  -v "$WS_ROOT":/workspace \
  --entrypoint /bin/bash \
  "$IMAGE_NAME" -c "
set -e
source /opt/ros/humble/setup.bash
mkdir -p /tmp/gen
cd /tmp/gen
ros2 pkg create --build-type ament_python --license Apache-2.0 '$PKG_NAME'
$RM_TESTS_CMD
$COPY_CMD
"

echo "Fixing ownership..."
sudo chown -R "$(id -u):$(id -g)" "$WS_ROOT"

echo "Done."
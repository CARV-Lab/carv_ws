# carv_ws
The ROS 2 half of LaunchSpot: one Docker image, one Compose project, one colcon workspace for
driving a Boston Dynamics Spot and streaming its data to Foxglove. Everything builds a single image, `carv:latest`, on top of a **pre-built** base image,
`spot_ros2:latest`, which carries the Spot driver and its message packages.

# Setup
## 1. Clone the repository and initialize submodules:
```bash
git clone https://github.com/CARV-Lab/carv_ws.git
cd carv_ws
git submodule init
git submodule update
```
## 2. Set the credentials in `config/robot.env`
## 3. Build and Run
```bash
docker compose up -d --build
```
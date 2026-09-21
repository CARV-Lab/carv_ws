FROM spot_ros2:latest

# ROS Packages
RUN apt-get update && apt-get install -y \
      ros-humble-foxglove-bridge \
      ros-humble-foxglove-msgs \
      ros-humble-velodyne-driver \
      ros-humble-velodyne-pointcloud \
      ros-humble-velodyne-msgs \
      ros-humble-slam-toolbox \
      ros-humble-pointcloud-to-laserscan \
      ros-humble-rosbag2-storage-mcap && \
    rm -rf /var/lib/apt/lists/*

# General Packages
RUN apt-get update && apt-get install -y \
      python3-sklearn && \
    rm -rf /var/lib/apt/lists/*

# Reads launch.yaml and parses args
COPY scripts/spot-launch /usr/local/bin/spot-launch
RUN chmod +x /usr/local/bin/spot-launch

# Source ROS for docker-compose services
COPY scripts/entrypoint.sh /ros_entrypoint.sh
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]

# Build Packages
WORKDIR /carv_ws
COPY src src
RUN . /opt/ros/humble/setup.sh && \
    . /ros_ws/install/setup.sh && \
    colcon build --symlink-install

# Source ROS for docker exec commands.
RUN printf '%s\n' \
      'source /opt/ros/humble/setup.bash' \
      'source /ros_ws/install/setup.bash' \
      'source /carv_ws/install/setup.bash' > /etc/ros_setup.sh && \
    echo '[ -f /etc/ros_setup.sh ] && . /etc/ros_setup.sh' >> /etc/bash.bashrc
ENV BASH_ENV=/etc/ros_setup.sh
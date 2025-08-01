#!/bin/bash
 
# Define the mount point
MOUNT_POINT="/mnt/backup"
 
# Check if the mount point exists and is a mount point
if mountpoint -q "$MOUNT_POINT"; then
  echo "Mount point $MOUNT_POINT is mounted. Proceeding with backup."
  exit 0
else
  echo "Mount point $MOUNT_POINT is NOT mounted. Aborting backup."
  # You can add a command here to attempt to mount the partition if you want.
  # For example: sudo mount -a
  exit 1
fi

#!/bin/bash
#
# delete_old_kernels_keep_multiple_with_purge.sh
#
# Description:
#   This script safely removes old kernels from an Ubuntu system while
#   keeping the current running kernel and a specified number of the newest
#   versions. It also cleans up dependencies and leftover configuration files.
#
# Usage:
#   1) chmod +x delete_old_kernels_keep_multiple_with_purge.sh
#   2) sudo ./delete_old_kernels_keep_multiple_with_purge.sh
#
# Notes:
#   - Adjust the KEEP variable to decide how many of the newest kernels to
#     retain in addition to your current kernel.
#

# Exit immediately if a command exits with a non-zero status.
set -e

# -----------------------
# CONFIGURATION
# -----------------------
# Number of latest kernel versions to keep (excluding the running kernel if it's older)
KEEP=2

# -----------------------
# MAIN SCRIPT
# -----------------------

# Check if we have root privileges
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run with sudo or as root."
   exit 1
fi

# Ensure KEEP is a positive number to prevent accidental deletion
if (( KEEP <= 0 )); then
    echo "[ERROR] The KEEP variable must be a positive integer."
    exit 1
fi

echo "[INFO] Detecting your current kernel..."
CURRENT_KERNEL_VER="$(uname -r)"
echo "      Currently running kernel: ${CURRENT_KERNEL_VER}"
echo

# Get all installed linux-image packages and their versions
ALL_KERNEL_PKGS=($(dpkg --list | awk '/^ii/ && /linux-image-[0-9]/ {print $2}'))
NUM_INSTALLED=${#ALL_KERNEL_PKGS[@]}

if (( NUM_INSTALLED <= KEEP + 1 )); then
  echo "[INFO] Only $NUM_INSTALLED kernel(s) installed, which is <= KEEP ($KEEP) + 1."
  echo "[INFO] Nothing to remove. Proceeding to cleanup steps."
else
  # Get all kernel versions, sort them, and get a list of what to remove
  ALL_KERNEL_VERSIONS=($(printf '%s\n' "${ALL_KERNEL_PKGS[@]}" | sed 's/linux-image-//' | sort -V))
  NUM_VERSIONS=${#ALL_KERNEL_VERSIONS[@]}

  # Determine which kernels to keep based on the latest versions and the current kernel
  KEEP_VERSIONS=("${ALL_KERNEL_VERSIONS[@]:$((NUM_VERSIONS - KEEP))}")
  KEEP_VERSIONS+=("$CURRENT_KERNEL_VER")
  KEEP_VERSIONS_UNIQUE=($(printf '%s\n' "${KEEP_VERSIONS[@]}" | sort -u))

  echo "[INFO] All installed kernel versions (oldest -> newest):"
  printf '      %s\n' "${ALL_KERNEL_VERSIONS[@]}"
  echo

  echo "[INFO] Keeping the newest $KEEP kernel(s) + the running kernel."
  echo "[INFO] Final keep list (versions):"
  printf '      %s\n' "${KEEP_VERSIONS_UNIQUE[@]}"
  echo

  KERNELS_TO_REMOVE=()
  for KERNEL_PKG in "${ALL_KERNEL_PKGS[@]}"; do
    VERSION="${KERNEL_PKG#linux-image-}"

    # Check if this VERSION is NOT in the keep list
    if ! printf '%s\n' "${KEEP_VERSIONS_UNIQUE[@]}" | grep -qx "$VERSION"; then
      echo "[REMOVE] $KERNEL_PKG"
      KERNELS_TO_REMOVE+=("$KERNEL_PKG")
    else
      echo "[KEEP]  $KERNEL_PKG"
    fi
  done

  # If there are kernels to remove, purge them
  if [ ${#KERNELS_TO_REMOVE[@]} -gt 0 ]; then
    echo
    echo "[INFO] Purging old kernel packages..."
    sudo apt-get purge -y "${KERNELS_TO_REMOVE[@]}"
  else
    echo
    echo "[INFO] No old kernels to remove."
  fi
fi

# Run autoremove and purge orphaned config files
echo
echo "---"
echo
echo "[INFO] Running autoremove for any unused dependencies..."
sudo apt-get autoremove -y

echo
echo "---"
echo
echo "[INFO] Checking for leftover 'rc' packages..."
RC_PACKAGES=$(dpkg --list | awk '/^rc/ { print $2 }')

if [ -n "$RC_PACKAGES" ]; then
  echo "[INFO] Purging leftover config files..."
  sudo dpkg -P $RC_PACKAGES
else
  echo "[INFO] No leftover 'rc' packages found."
fi

echo
echo "---"
echo
echo "[INFO] Final check of installed kernel packages:"
dpkg --list | grep 'linux-image-[0-9]'

echo
echo "[INFO] Script complete. Current kernel remains: ${CURRENT_KERNEL_VER}"

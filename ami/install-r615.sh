#!/usr/bin/env bash
set -euo pipefail

if [[ "${NVIDIA_DRIVER_VERSION}" != 615.* ]]; then
  echo "Expected an R615 driver version, got ${NVIDIA_DRIVER_VERSION}" >&2
  exit 1
fi

kernel_package="kernel"
case "$(uname -r)" in
  6.12.*) kernel_package="kernel6.12" ;;
  6.18.*) kernel_package="kernel6.18" ;;
esac

sudo dnf install -y \
  dnf-plugin-versionlock \
  "${kernel_package}-devel-$(uname -r)" \
  "${kernel_package}-headers" \
  "${kernel_package}-modules-extra" \
  "${kernel_package}-modules-extra-common"

sudo dnf config-manager --add-repo \
  https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
sudo dnf clean expire-cache

sudo dnf module reset -y nvidia-driver
sudo dnf module install -y nvidia-driver:615-open/default
sudo dnf install -y nvidia-container-toolkit

# `dnf module install nvidia-driver:615-open/default` always installs
# whatever build the CUDA repo currently publishes as the default for the
# 615-open stream, not the exact NVIDIA_DRIVER_VERSION requested above. That
# input is only a branch selector (validated as 615.* up front) -- the repo
# moves forward within the branch on NVIDIA's own release cadence (e.g.
# 615.71.09 -> 615.71.10), independent of this script. Discover the version
# that actually got installed from the installed package itself, and use
# THAT for versionlock and verification, so the build does not fail every
# time the upstream repo ships a new point release on the same branch.
installed_driver_version="$(rpm -q --qf '%{VERSION}\n' nvidia-driver)"
if [[ "${installed_driver_version}" != 615.* ]]; then
  echo "Installed driver ${installed_driver_version} is not on the requested R615 branch (${NVIDIA_DRIVER_VERSION})" >&2
  exit 1
fi
echo "Requested branch ${NVIDIA_DRIVER_VERSION}; dnf installed ${installed_driver_version}"

sudo dnf versionlock add \
  "nvidia-*-${installed_driver_version}*" \
  "kmod-nvidia-open-dkms-${installed_driver_version}*"

sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default

printf 'options nvidia NVreg_CoherentGPUMemoryMode=driver\n' \
  | sudo tee /etc/modprobe.d/40-eks-nvidia-openrm.conf >/dev/null

sudo systemctl enable nvidia-persistenced.service

dkms_status="$(dkms status -m nvidia -v "${installed_driver_version}")"
printf '%s\n' "${dkms_status}"
grep -q "${installed_driver_version}.*installed" <<<"${dkms_status}"

installed_driver_packages="$(rpm -qa | grep -E '^(nvidia|kmod-nvidia)' | sort)"
printf '%s\n' "${installed_driver_packages}"
grep -q "${installed_driver_version}" <<<"${installed_driver_packages}"
rpm -q nvidia-container-toolkit

printf '%s\n' "${installed_driver_version}" | sudo tee /etc/eks-runai-nvidia-driver-version >/dev/null

sudo dnf clean all
sudo rm -rf /var/cache/dnf

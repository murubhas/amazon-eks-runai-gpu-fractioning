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

sudo dnf versionlock add \
  "nvidia-*-${NVIDIA_DRIVER_VERSION}*" \
  "kmod-nvidia-open-dkms-${NVIDIA_DRIVER_VERSION}*"

sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default

printf 'options nvidia NVreg_CoherentGPUMemoryMode=driver\n' \
  | sudo tee /etc/modprobe.d/40-eks-nvidia-openrm.conf >/dev/null

sudo systemctl enable nvidia-persistenced.service

dkms_status="$(dkms status -m nvidia -v "${NVIDIA_DRIVER_VERSION}")"
printf '%s\n' "${dkms_status}"
grep -q "${NVIDIA_DRIVER_VERSION}.*installed" <<<"${dkms_status}"

installed_driver_packages="$(rpm -qa | grep -E '^(nvidia|kmod-nvidia)' | sort)"
printf '%s\n' "${installed_driver_packages}"
grep -q "${NVIDIA_DRIVER_VERSION}" <<<"${installed_driver_packages}"
rpm -q nvidia-container-toolkit

sudo dnf clean all
sudo rm -rf /var/cache/dnf

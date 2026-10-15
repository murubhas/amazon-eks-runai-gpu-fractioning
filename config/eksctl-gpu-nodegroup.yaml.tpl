apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: __CLUSTER_NAME__
  region: __AWS_REGION__
  version: "__EKS_VERSION__"

managedNodeGroups:
  - name: gpu-g5-r615-ondemand
    instanceType: __GPU_INSTANCE_TYPE__
    ami: __AMI_ID__
    amiFamily: AmazonLinux2023
    desiredCapacity: 1
    minSize: 1
    maxSize: 1
    privateNetworking: true
    disableIMDSv1: true
    volumeSize: 100
    volumeType: gp3
    labels:
      workload: runai-fractioning
      gpu-stack: gpu-operator
    taints:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
    tags:
      node-role: runai-fractioning-gpu
      nvidia-driver: "__NVIDIA_DRIVER_VERSION__"
      auto-delete: "yes"
    updateConfig:
      maxUnavailable: 1

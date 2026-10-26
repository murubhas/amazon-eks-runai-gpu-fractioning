apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: __CLUSTER_NAME__
  region: __AWS_REGION__
  version: "__EKS_VERSION__"
  tags:
    project: amazon-eks-runai-gpu-fractioning
    purpose: disposable-sample-validation
    auto-delete: "yes"

iam:
  withOIDC: true

vpc:
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
  publicAccessCIDRs: __EKS_PUBLIC_ACCESS_CIDRS__
  nat:
    gateway: Single

managedNodeGroups:
  - name: system-ondemand
    instanceType: m7i.large
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    privateNetworking: true
    disableIMDSv1: true
    volumeSize: 50
    volumeType: gp3
    labels:
      workload: system
    tags:
      node-role: system
      auto-delete: "yes"
    updateConfig:
      maxUnavailable: 1

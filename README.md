# NVIDIA Run:ai GPU Fractioning on Amazon EKS

This sample demonstrates GPU memory sharing among Kubernetes Pods on Amazon
EKS using compatible NVIDIA GPUs. The validated walkthrough places two
GPU-memory-bounded Pods on one NVIDIA A10G in a `g5.xlarge` worker. It builds a
custom EKS 1.36 Amazon Linux 2023 (AL2023) image with the NVIDIA R615 open
driver, installs NVIDIA GPU Operator without replacing the image-owned driver
or toolkit, and deploys KAI Scheduler with the NVIDIA Run:ai GPU Fractioning
Operator. Other GPU configurations must meet the upstream compatibility
requirements and have not been validated by this sample.

On October 13, 2026, NVIDIA announced that the full NVIDIA Run:ai platform is
available as open-source software as part of NVIDIA DSX AI Factory. The platform
can be adopted as an integrated whole or through modular components. This sample
uses KAI Scheduler and GPU Fractioning Operator, two of the release's four
modular components. KAI Resource Management and Workload Map are outside this
walkthrough's scope. Community software does not include NVIDIA enterprise
support.

> This sample creates billable AWS resources, including an EKS control plane, a
> NAT gateway, EC2 instances, EBS volumes, and an AMI snapshot. Run the cleanup
> step when testing is complete.

## Architecture

![Architecture showing the EKS control plane in an AWS-managed VPC and private system and GPU workers in the customer VPC, with two GPU-memory contracts on one A10G](docs/runai-fractioning-architecture.png)

[Open the editable architecture diagram](docs/runai-fractioning-architecture.svg)

The disposable cluster contains one `m7i.large` system node and one On-Demand
`g5.xlarge` GPU node. The G5 node uses the custom AL2023 image and exposes one
NVIDIA A10G. Two Pods each receive an 8 GiB view of the same physical GPU and
allocate 6 GiB concurrently.

The diagram separates the AWS-managed control-plane VPC from the customer
Amazon Virtual Private Cloud (Amazon VPC) that contains the private workers.
The system node hosts the controllers and scheduler; node-level GPU Operator
components and fractioning daemons also run on the GPU worker. The GPU worker
combines the custom AL2023 host stack, containerd NRI, and NVIDIA MPS with
per-Pod GPU-memory limits and metrics.

This is the steady-state test architecture. The temporary Packer builder,
public build subnet, and NAT gateway are not shown. The illustrated Region,
`us-east-2`, is the validation Region, not a requirement. Other Regions require
the same EKS version, base AMI, instance types, quota, and available capacity;
they have not been validated by this sample. The AMI build targets x86_64.

## What the sample proves

1. In this sample's NVIDIA device-plugin baseline, sharing is disabled and the
   A10G exposes one integer `nvidia.com/gpu` resource. One whole-GPU Pod runs
   and a second remains Pending.
2. With two 8 GiB Run:ai memory contracts, both Pods run on the same node and
   GPU UUID.
3. Each Pod successfully allocates 6 GiB within its contract.
4. A 9 GiB allocation is rejected inside an 8 GiB contract.
5. GPU fractioning metrics attribute memory consumption to each Pod.

These are synthetic CUDA memory-allocation tests, not model-serving or
throughput benchmarks. The baseline does not describe every Kubernetes GPU
allocation mode: NVIDIA MIG, device-plugin sharing, and Dynamic Resource
Allocation (DRA) are separate options with different requirements and
isolation properties.

## Prerequisites

### AWS account and credentials

Use an AWS account with sufficient quota and permissions to create and delete
EKS, CloudFormation, VPC, EC2, EBS, IAM, and related resources. The identity
also needs `ssm:GetParameter` to discover the recommended EKS AL2023 base AMI.

Configure the AWS CLI through any supported credential provider, such as:

- An AWS CLI named profile or IAM Identity Center profile
- An assumed role
- An EC2 or development-environment role
- Access key and secret access key environment credentials

Roles, IAM Identity Center, and temporary credentials are preferred. If access
keys are required, place them only in the local ignored `walkthrough.env`, set
the file permission to `600`, and never commit or share that file.

The repository's prerequisite check prints the active AWS identity before it
creates anything. A named profile and Region can be set in `walkthrough.env`
after cloning.

Confirm that the Region has `g5.xlarge` capacity and that the account has enough
EC2 On-Demand G and VT instance quota for one G5 node and the temporary Packer
builder. Capacity is not guaranteed by this sample.

### Local tools

Install the following command-line tools:

- AWS CLI v2
- `eksctl`
- `kubectl`
- Helm 3 or 4
- HashiCorp Packer
- `jq`
- `curl`

## Clone and run

The reader-facing workflow uses only two files: `walkthrough.env` for optional
configuration and `run.sh` for every action. All manifests, Helm values, Packer
files, validation probes, and cleanup logic remain versioned behind that entry
point.

```bash
git clone https://github.com/murubhas/amazon-eks-runai-gpu-fractioning.git
cd amazon-eks-runai-gpu-fractioning
cp walkthrough.env.example walkthrough.env
chmod 600 walkthrough.env
```

Edit `walkthrough.env` only when the defaults do not match your AWS environment.
Choose either a named profile or access-key variables; do not configure both.
Verify the local tools and active AWS identity before provisioning anything:

```bash
./run.sh check
```

Then either run one stage at a time, as shown below, or run the complete
validation through the negative test:

```bash
./run.sh walkthrough
```

The wrapper never performs cleanup automatically, so the evidence remains
available for inspection. Run `./run.sh cleanup` when validation is complete.

## Configure the walkthrough

The checked-in `walkthrough.env.example` contains these defaults:

```bash
AWS_REGION=us-east-2
CLUSTER_NAME=runai-fractioning-blog
EKS_VERSION=1.36
GPU_INSTANCE_TYPE=g5.xlarge
NVIDIA_DRIVER_VERSION=615.71.10

# Optional: trusted IPv4 CIDRs for the public EKS API
# EKS_PUBLIC_ACCESS_CIDRS=YOUR_PUBLIC_IPV4/32

# Authentication option 1: named profile
# AWS_PROFILE=my-profile

# Authentication option 2: access keys
# AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY=YOUR_SECRET_ACCESS_KEY
# AWS_SESSION_TOKEN=YOUR_SESSION_TOKEN
```

`AWS_SESSION_TOKEN` is needed only for temporary credentials. When none of the
credential variables is set, the AWS CLI and Packer use their normal credential
provider chains. `run.sh` exports the selected configuration to every stage.
Generated kubeconfig, AMI IDs, rendered eksctl files, and logs are written to
the ignored `.state` directory. Newly created state files use owner-only
permissions. Do not upload `.state`, local credentials, or raw logs without
reviewing and redacting them.

### Network access

For a new cluster, `create-cluster` discovers the operator machine's public
IPv4 address using `https://checkip.amazonaws.com` and restricts the public EKS
API endpoint to that address (`/32`). Private endpoint access remains enabled
for the workers. If discovery fails, creation stops rather than falling back
to unrestricted access. For a stable VPN or automation egress range, set
`EKS_PUBLIC_ACCESS_CIDRS` to trusted IPv4 CIDRs separated by commas, without
spaces. Invalid CIDRs and `/0` access are rejected.

The temporary Packer builder also restricts SSH to the public IP of the machine
running Packer. Neither an internet-wide SSH rule nor an unrestricted EKS API
source range is required by the sample. AWS and Kubernetes authentication are
still required for API access.

Keep your egress IP stable while creating and operating the lab. If it changes,
update the cluster's allowed CIDRs using the [EKS endpoint access
instructions](https://docs.aws.amazon.com/eks/latest/userguide/config-cluster-endpoint.html).
Rerunning `create-cluster` refreshes kubeconfig for an existing cluster but does
not change that cluster's endpoint restrictions. Do not reuse an existing
production cluster for this walkthrough.

## Step 1 Create the disposable EKS cluster

```bash
./run.sh create-cluster
```

The command creates a dedicated VPC, an EKS 1.36 control plane, and one private
`m7i.large` managed node. The cluster is intentionally separate from existing
development and production clusters.

## Step 2 Build the custom AL2023 R615 image

```bash
./run.sh build-ami
```

The script performs these actions:

1. Finds a public subnet in the disposable cluster VPC for the temporary Packer
   builder.
2. Retrieves the current recommended EKS 1.36 AL2023 x86 standard AMI from the
   AWS Systems Manager public parameter.
3. Installs the NVIDIA R615 open-driver stream and NVIDIA Container Toolkit.
4. Configures NVIDIA as the default containerd runtime and verifies DKMS and RPM
   state.
5. Creates an encrypted custom AMI and records its ID in `.state/ami-id`.

Set `SOURCE_AMI_ID` or `PACKER_SUBNET_ID` before running the command when you
need to pin a previously approved base image or use a different builder subnet.

## Step 3 Add one G5 worker

```bash
./run.sh add-gpu-node
```

The node group stays at exactly one On-Demand `g5.xlarge`. It is tainted so
ordinary workloads do not consume the GPU. The script prevents eksctl from
installing a separate NVIDIA device plugin because GPU Operator owns that
component.

## Step 4 Install GPU Operator and inspect the host stack

```bash
./run.sh install-gpu-operator
```

The values file deliberately sets `driver.enabled=false` and
`toolkit.enabled=false`. The custom AMI owns the host driver and toolkit; GPU
Operator supplies the remaining Kubernetes GPU components, including the
device plugin.

The script runs a short-lived privileged inspection Pod in this disposable
environment. It reports the GPU model and memory, driver, toolkit, containerd,
cgroup filesystem, and NRI socket, and then removes itself.

## Step 5 Establish the whole-GPU baseline

```bash
./run.sh baseline
```

Expected result: one Pod is Running and one is Pending because this baseline
advertises one `nvidia.com/gpu` resource without sharing enabled. The script
records the state and removes both baseline Pods.

## Step 6 Install KAI Scheduler and GPU Fractioning

```bash
./run.sh install-kai
```

The command installs the official pinned OCI chart:

```text
oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler:v0.18.5
```

The chart includes GPU Fractioning Operator `v0.1.7`. The script waits for the
default fractioning configuration and the G5 node's fractioning readiness
condition.

## Step 7 Run the positive sharing test

```bash
./run.sh share
```

The test creates two Pods with identical 8 GiB request and limit annotations.
Neither requests a whole `nvidia.com/gpu`. Each compiles a small CUDA program,
allocates 6 GiB, and holds the allocation so both Pods can be observed together.
The script verifies that both Pods use the same node and GPU UUID.

Expected placement:

```text
NAME             READY   STATUS    NODE
fraction-8gi-a   1/1     Running   <same-gpu-node>
fraction-8gi-b   1/1     Running   <same-gpu-node>
```

## Step 8 Observe per-Pod GPU memory

Run this command while the two positive-test Pods are still active:

```bash
./run.sh metrics
```

Expected output includes one `gpu_fractioning_gpu_memory_used_bytes` series for
each test Pod.

## Step 9 Prove the memory limit

```bash
./run.sh limit
```

The script replaces the positive-test Pods with one Pod that has the same 8 GiB
contract but attempts to allocate 9 GiB. The CUDA allocation must fail with
`out of memory`; the Pod exits successfully because rejection is the expected
test result.

Expected Pod status:

```text
NAME                      READY   STATUS      NODE
fraction-8gi-over-limit   0/1     Completed   <gpu-node>
```

`Completed` is expected: the probe exits with code 0 only after confirming that
CUDA rejected the oversized allocation.

## Step 10 Clean up

```bash
./run.sh cleanup
```

Cleanup removes the test namespace, Helm releases, managed nodes, EKS control
plane, CloudFormation stacks, and disposable VPC. Before deletion, the script
requires the ownership tags created by this sample. It preserves the reusable
AMI and its EBS snapshot by default.

Delete the image only after confirming that it is not needed elsewhere:

```bash
./run.sh cleanup-all
```

## Validated component set

The first validation ran on October 15, 2026 with driver 615.71.09. The complete
walkthrough was revalidated on October 22, 2026 with the component set below:

| Component | Validated version |
| --- | --- |
| Amazon EKS | 1.36 |
| EC2 GPU instance | `g5.xlarge`, NVIDIA A10G 23028 MiB |
| Amazon Linux | EKS-optimized AL2023 standard base image |
| NVIDIA driver | 615.71.10 open kernel modules |
| NVIDIA Container Toolkit | 1.20.1-1 |
| containerd | 2.3.5 |
| NVIDIA GPU Operator | 26.7.1 |
| NVIDIA device plugin | 0.20.1 |
| KAI Scheduler | 0.18.5 |
| GPU Fractioning Operator | 0.1.7 |

See [validated results](docs/VALIDATED-RESULTS.md) for the measured acceptance
evidence.

The NVIDIA driver version tracks the current point release of the R615 open
kernel-module stream in NVIDIA's CUDA repository. The October 15, 2026 run
observed 615.71.09; the full walkthrough was re-validated end to end on
615.71.10 after the stream advanced, with identical results. The build
installs whatever point release the 615-open stream currently serves, so
expect this value to move forward over time.

The build discovers the installed R615 point release, version-locks it in the
image, and records it in the AMI tag and node-group metadata. This avoids
assuming that NVIDIA's repository still serves an older patch, but it does
not guarantee compatibility with future releases. Rerun the acceptance tests
after rebuilding or changing any component.

## Production considerations

- GPU memory fractioning is not a hard multi-tenant security boundary. Use
  whole-GPU allocation or NVIDIA MIG on supported devices when stronger fault,
  security, or performance isolation is required.
- Size contracts from measured peak memory and retain headroom for CUDA
  contexts, kernels, caches, batching, the driver, and the runtime.
- Measure latency and throughput under concurrent load. A memory fit does not
  guarantee acceptable compute performance.
- Pin and govern the EKS base image, driver, toolkit, GPU Operator, KAI chart,
  workload images, and their digests as one tested compatibility set.
- Rebuild custom images from approved bases rather than upgrading GPU packages
  in place on long-lived nodes.
- Apply least-privilege IAM, admission policies, trusted-image controls,
  namespace isolation, network policies, monitoring, and automated cleanup.

## Repository layout

```text
ami/          Packer template and R615 installation script
config/       eksctl templates rendered into the ignored .state directory
docs/         Architecture and point-in-time validation evidence
helm/         GPU Operator and KAI values
kubernetes/   Namespaces, host inspection, and acceptance-test workloads
scripts/      Ordered create, validate, observe, and cleanup commands
run.sh        Single reader-facing command entry point
walkthrough.env.example  Optional configuration template
tests/        Mocked regression suites; no live AWS resources are required
```

## Local regression tests

With Bash and `jq` installed, run each suite separately:

```bash
bash tests/run-install-r615-tests.sh
bash tests/run-build-ami-tests.sh
bash tests/run-cleanup-tests.sh
bash tests/run-network-access-tests.sh
```

The suites mock AWS and provisioning tools. They check driver drift, metadata
propagation, cleanup safety, and network-access configuration; they do not
replace a live walkthrough or measure GPU performance.

## References

- [NVIDIA Run:ai open-source announcement](https://developer.nvidia.com/blog/nvidia-runai-is-now-open-source-as-part-of-nvidia-dsx-ai-factory-platform/)
- [KAI Scheduler](https://github.com/kai-scheduler/KAI-Scheduler)
- [GPU Fractioning Operator](https://github.com/kai-scheduler/gpu-fractioning)
- [Amazon EKS optimized accelerated AMIs](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html)
- [Retrieve recommended Amazon EKS AMI IDs](https://docs.aws.amazon.com/eks/latest/userguide/retrieve-ami-id.html)
- [Amazon EKS API endpoint access](https://docs.aws.amazon.com/eks/latest/userguide/config-cluster-endpoint.html)
- [NVIDIA GPU sharing with GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html)

## Authors

- Muru Bhaskaran, Sr. Specialist Solutions Architect, Amazon Web Services
- Robert Ferrer, Specialist Solutions Architect, Amazon Web Services

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

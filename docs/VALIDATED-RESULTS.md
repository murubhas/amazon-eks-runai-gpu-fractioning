# Validated Results

The sample was first validated on October 15, 2026 in `us-east-2` on a
disposable Amazon EKS 1.36 cluster with one On-Demand `g5.xlarge` worker, and
the full walkthrough was re-validated end to end on October 22, 2026 under the
same configuration. Account IDs, instance IDs, subnet IDs, AMI IDs, node names,
and GPU UUIDs are intentionally omitted.

The NVIDIA driver version tracks the current point release of the R615 open
kernel-module stream. The October 15, 2026 run observed 615.71.09. After the
stream advanced, the October 22, 2026 run rebuilt the custom AMI and reran the
complete walkthrough — host stack inspection and every acceptance test — on
615.71.10. Both the host stack and the acceptance results below were identical
to the October 15 run except for the driver point release and the GPU UUID. The
driver value below reflects the current 615-open point release; the October 15,
2026 results remain valid as the original evidence on 615.71.09.

## Host stack

| Check | Observed result |
| --- | --- |
| GPU | NVIDIA A10G, 23028 MiB |
| Driver | 615.71.10 open kernel modules |
| NVIDIA Container Toolkit | 1.20.1-1 |
| containerd | 2.3.5 |
| cgroups | cgroup v2 |
| NRI | Socket present |
| GPU Operator | ClusterPolicy ready |
| Device plugin | 0.20.1, `nvidia.com/gpu=1` advertised |
| KAI Scheduler | 0.18.5 |
| GPU Fractioning Operator | 0.1.7, ready |

## Acceptance evidence

Every acceptance criterion below was reproduced on both the October 15, 2026
run (driver 615.71.09) and the October 22, 2026 re-validation (driver
615.71.10), with identical observed results.

| Acceptance criterion | Observed result | Status |
| --- | --- | --- |
| Whole-GPU baseline | One Pod Running and one Pending | Passed |
| Co-location | Two contracts used one node and GPU UUID | Passed |
| Bounded device view | Each Pod saw 8192 MiB | Passed |
| In-limit allocation | Each Pod allocated 6144 MiB | Passed |
| Over-limit allocation | A 9216 MiB allocation failed with out of memory | Passed |
| Per-Pod metrics | Approximately 6.70 GB attributed to each Pod | Passed |

## Pod state evidence

The positive test placed both 8 GiB contracts on the same GPU node:

```text
NAME             READY   STATUS    NODE
fraction-8gi-a   1/1     Running   <same-gpu-node>
fraction-8gi-b   1/1     Running   <same-gpu-node>
```

The negative test completed successfully after the 8 GiB contract rejected a
9 GiB CUDA allocation:

```text
NAME                      READY   STATUS      NODE
fraction-8gi-over-limit   0/1     Completed   <gpu-node>
```

`Completed` is the expected state because the probe exits with code 0 only when
the oversized allocation is rejected.

## Cleanup evidence

After evidence capture, the test namespace and Helm releases were removed and
the disposable cluster was deleted. Independent AWS queries returned no EKS
cluster, cluster CloudFormation stacks, cluster-tagged EC2 instances, or
sample-tagged VPC. The reusable custom AMI and its encrypted EBS snapshot were
preserved intentionally.

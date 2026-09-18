# Derived from the upstream nixlbench container image.
#
# The upstream image (benchmark/nixlbench/contrib/Dockerfile in ai-dynamo/nixl)
# installs libnuma-dev, which provides only the headers and shared library that
# programs link against. The numactl package -- which ships numactl(8) and
# numastat(8) -- is not installed, so NUMA-bound runs are impossible inside the
# container.
#
# Binding nixlbench's DRAM buffers to a CPU-less CXL memory node relies entirely
# on `numactl --membind`, and verifying the placement relies on `numastat -p`.
# This layer adds both. It is a few MB on top of the base image, so rebuilding
# and pushing is fast and the large upstream layers are never re-transferred.

ARG BASE_IMAGE=nixlbench:v1.3.1.dev.d2495941
FROM ${BASE_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends numactl \
 && rm -rf /var/lib/apt/lists/*

#!/usr/bin/env python3
"""Example: build, measure, and deploy pipeline.

Shows how to use the SDK programmatically for CI/CD or custom scripts.
The TDXfile defines the image; this script orchestrates the workflow.
"""

from pathlib import Path

from tdx import Image, Build, Kernel
from tdx.measure import measure, verify
from tdx.deploy import deploy

# --- Image definition (or import from a TDXfile) ---

image = Image("my-prover", base="debian/bookworm")
image.kernel = Kernel.tdx(version="6.8")
image.install("ca-certificates")
image.debloat()

image.build(Build.go(
    name="my-prover",
    src="./prover/",
    go_version="1.22",
    output="/usr/local/bin/my-prover",
))

image.service(
    name="my-prover",
    exec="/usr/local/bin/my-prover",
    user="prover",
)
image.user("prover", system=True)

# --- Build ---

result = image.build(output_dir="build")
print(f"Image built: {result.image_path}")
# result.image_path  → Path("build/my-prover.raw")
# result.kernel_path → Path("build/my-prover.vmlinuz")

# --- Measure ---

# Raw TDX: compute RTMRs
rtmrs = measure(result, backend="rtmr")
print(f"RTMR[0] (firmware): {rtmrs[0]}")
print(f"RTMR[1] (kernel):   {rtmrs[1]}")
print(f"RTMR[2] (rootfs):   {rtmrs[2]}")
rtmrs.to_json("build/measurements.json")

# Azure CVM: compute vTPM PCRs
pcrs = measure(result, backend="azure")
print(f"PCR[4]  (bootloader): {pcrs[4]}")
print(f"PCR[11] (UKI hash):   {pcrs[11]}")
pcrs.to_json("build/azure-measurements.json")

# --- Verify a running VM (after deployment) ---
# quote_path = Path("./quote.bin")  # obtained from the running VM
# verify(quote=quote_path, expected=rtmrs)

# --- Deploy ---

# Local QEMU for testing
deploy(result, target="qemu", memory="4G", cpus=2, vsock_cid=3)

# Or to Azure
# deploy(result, target="azure",
#     resource_group="my-rg",
#     vm_size="Standard_DC4as_v5",
#     location="eastus",
# )

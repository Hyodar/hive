#!/usr/bin/env python3
"""Example: build, measure, and deploy pipeline.

Shows how to use the SDK programmatically for CI/CD or custom scripts.
Everything hangs off Image — no separate imports needed.
"""

from pathlib import Path
from tdx import Image, Build, Kernel

# --- Image definition ---

img = Image(build_dir="build", base="debian/bookworm")
img.kernel = Kernel.tdx(version="6.8")
img.install("ca-certificates")
img.debloat()

img.add_build(Build.go(
    name="my-prover",
    src="./prover/",
    go_version="1.22",
    output="/usr/local/bin/my-prover",
))

img.service(
    name="my-prover",
    exec="/usr/local/bin/my-prover",
    user="prover",
)
img.user("prover", system=True)

# --- Build ---

img.build()

# --- Measure ---

# Raw TDX: compute RTMRs
rtmrs = img.measure(backend="rtmr")
print(f"RTMR[0] (firmware): {rtmrs[0]}")
print(f"RTMR[1] (kernel):   {rtmrs[1]}")
print(f"RTMR[2] (rootfs):   {rtmrs[2]}")
rtmrs.to_json("build/measurements.json")

# Azure CVM: compute vTPM PCRs
with img.profile("azure"):
    pcrs = img.measure(backend="azure")
    print(f"PCR[4]  (bootloader): {pcrs[4]}")
    print(f"PCR[11] (UKI hash):   {pcrs[11]}")
    pcrs.to_json("build/azure-measurements.json")

# --- Verify a running VM (after deployment) ---
# rtmrs.verify(quote=Path("./quote.bin"))

# --- Deploy ---

# Local QEMU for testing
img.deploy(target="qemu", memory="4G", cpus=2, vsock_cid=3)

# Or to Azure
# img.deploy(target="azure",
#     resource_group="my-rg",
#     vm_size="Standard_DC4as_v5",
#     location="eastus",
# )

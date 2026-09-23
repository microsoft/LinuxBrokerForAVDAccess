"""Verify the locked Linux runtime archive locally, without installing or selecting it."""

import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "broker_runtime_installer", REPO / "custom_script_extensions" / "install-broker-python.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--staging-parent", type=Path,
                        help="Existing case-sensitive Linux filesystem for this invocation's temporary extraction.")
    args = parser.parse_args()
    if sys.platform != "linux" or platform.machine() != "x86_64":
        raise RuntimeError("Run this archive-execution check on local Linux x86_64, not a deployed broker host.")
    config = runtime.validate_config(json.loads((REPO / "deploy" / "linux-python.lock.json").read_text()))
    if runtime.file_hash(args.archive) != config["sha256"]:
        raise RuntimeError("The local archive does not match the checked-in runtime lock.")
    readelf = shutil.which("readelf")
    if not readelf:
        raise RuntimeError("readelf is required to verify the runtime's glibc symbol requirements.")
    staging_parent = args.staging_parent or REPO / "deploy" / ".artifacts" / "python-runtime"
    staging_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="runtime-probe-", dir=str(staging_parent)) as temporary:
        expanded = Path(temporary)
        runtime.extract_runtime(args.archive, expanded)
        binary = expanded / "python" / "bin" / ("python" + ".".join(config["version"].split(".")[:2]))
        result = subprocess.run(
            [str(binary), "-I", "-c",
             "import argparse,dataclasses,fcntl,hashlib,json,pathlib,subprocess,sys,uuid; print(sys.version.split()[0])"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
        )
        if result.stdout.strip() != config["version"]:
            raise RuntimeError("The archive runtime version did not match the lock.")
        versions = set()
        elf_count = 0
        for path in (expanded / "python").rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) != b"\x7fELF":
                    continue
            elf_count += 1
            symbols = subprocess.run(
                [readelf, "--version-info", str(path)], check=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
            ).stdout
            versions.update(tuple(int(part) for part in match.split(".")) for match in
                            re.findall(r"\bGLIBC_([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b", symbols))
        if not elf_count or not versions or max(versions) > (2, 17):
            raise RuntimeError("Runtime ELF requirements exceed the RHEL7 glibc 2.17 baseline.")
        print("PASS: CPython {}, required stdlib, and {} ELF files; maximum glibc symbol {}. "
              "No system runtime or broker selector was changed.".format(
                  config["version"], elf_count, ".".join(str(part) for part in max(versions))))
    return 0


if __name__ == "__main__":
    sys.exit(main())

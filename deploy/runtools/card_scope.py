"""[TWO-CARD] Card-scoped operation for a host with several Alveo cards (opt-in).

Enabled only when the manager runs with FIRESIM_CARD_SCOPED=1. With the variable
unset nothing here is consulted and every manager command is stock FireSim.

In card-scoped mode a manager touches only the card(s) named in its own
default_fpga_db:
  - PCIe/xdma handling is STOCK (owner 2026-10-30 15:1x): infrasetup does rmmod xdma,
    remove, flash, global /sys/bus/pci/rescan, insmod exactly as unscoped FireSim
    (pcie_scoped() is hard-wired False; the old no-rmmod / --card-scoped branches are
    dead code). A stock infrasetup unbinds BOTH cards, so it may only run while
    neither card has a run in flight (lockstep campaigns),
  - screens are named fsim<slot>-<bus>; monitor and kill-confirm count only those,
  - kill matches only the driver started with +bus=0x<bus>,
  - the topology diagram is generated-topology-diagrams/...-card-<bus>.gv,
  - the flash (unload_xdma/flash_fpgas/load_xdma/perms) is serialized host-wide by
    a user flock; driver make+tar takes a second (build) flock exclusively, the
    infrasetup's copy of the driver tarball takes it shared (copies overlap each
    other, never a re-tar).
"""

import fcntl
import json
import os
import re
from typing import IO, List, Optional

ENV_FLAG = "FIRESIM_CARD_SCOPED"


def enabled() -> bool:
    return os.environ.get(ENV_FLAG, "") == "1"


def pcie_scoped() -> bool:
    """Card-scoped PCIe/xdma handling (no rmmod/insmod, fpga-util --card-scoped).
    Hard-wired OFF (owner 2026-10-30 15:1x: anything touching xdma or PCIe uses the
    default FireSim flow). No environment variable can turn it on."""
    return False


def db_buses(fpga_db_path: str) -> List[str]:
    """Bus ids (2 hex digits, lower case) of every entry in an fpga db, in slot order."""
    with open(fpga_db_path, "r") as f:
        db = json.load(f)
    buses = []
    for e in db:
        m = re.fullmatch(r"([0-9a-fA-F]{2}):[0-9a-fA-F]{2}\.[0-7]", e["bdf"])
        assert m is not None, f"[TWO-CARD] malformed bdf {e['bdf']!r} in {fpga_db_path}"
        buses.append(m.group(1).lower())
    assert len(buses) > 0, f"[TWO-CARD] empty fpga db {fpga_db_path}"
    return buses


def screen_name(slotid: int, bus: str) -> str:
    return f"fsim{slotid}-{bus.lower()}"


def bus_from_driver_args(extra_args: Optional[str]) -> str:
    """The bus the driver is started with (+bus=0x3b); the screen tag is derived
    from this very string, so screen name and driver bus cannot disagree."""
    m = re.search(r"\+bus=0x([0-9a-fA-F]{2})(?:\s|$)", extra_args or "")
    assert m is not None, f"[TWO-CARD] {ENV_FLAG}=1 but no +bus=0x.. in driver args: {extra_args!r}"
    return m.group(1).lower()


def screen_regex(names: List[str]) -> "re.Pattern[str]":
    """Matches a `screen -ls` line whose session name is exactly one of names."""
    alt = "|".join(re.escape(n) for n in names)
    return re.compile(r"\d+\.(" + alt + r")\s")


def kill_command(driver_binary: str, bus: str) -> str:
    """SIGKILL only the driver whose argv0 is ./<driver> and whose arguments contain
    +bus=0x<bus>. Anchored at ^ so the SCREEN/bash/script wrappers (whose cmdlines
    also contain the driver string) and the pkill's own shell are not matched."""
    assert re.fullmatch(r"[A-Za-z0-9_.-]+", driver_binary), driver_binary
    assert re.fullmatch(r"[0-9a-f]{2}", bus.lower()), bus
    drv = driver_binary.replace(".", r"\.")
    pat = r"^\./" + drv + r" .*\+bus=0x" + bus.lower() + r"( |$)"
    return f"pkill -SIGKILL -f '{pat}'"


def gv_suffix(fpga_dbs: List[Optional[str]]) -> str:
    """Deterministic per-card topology-diagram suffix ('-card-5e'); pid if no db."""
    tags = set()
    for db in fpga_dbs:
        if db:
            try:
                tags.add("card-" + "-".join(db_buses(db)))
            except (OSError, ValueError, KeyError, AssertionError):
                pass
    if tags:
        return "-" + "-".join(sorted(tags))
    return f"-pid{os.getpid()}"


LOCK_FILES = {
    "flash": ("FIRESIM_CARD_LOCK", ".card-scope-flash.lock"),
    "build": ("FIRESIM_CARD_BUILD_LOCK", ".card-scope-build.lock"),
}


def lock_path(kind: str) -> str:
    """Host-wide user lock file in deploy/ (overridable for tests)."""
    env, name = LOCK_FILES[kind]
    if os.environ.get(env):
        return os.environ[env]
    from buildtools.bitbuilder import get_deploy_dir  # local import: avoid cycles

    return os.path.join(get_deploy_dir(), name)


class CardLock:
    """flock on lock_path(kind); shared=True for readers (tarball copy)."""

    def __init__(self, logger, kind: str, shared: bool = False) -> None:
        self.logger = logger
        self.kind = kind
        self.mode = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        self.fh: Optional[IO[str]] = None

    def __enter__(self) -> "CardLock":
        path = lock_path(self.kind)
        self.fh = open(path, "a+")
        try:
            fcntl.flock(self.fh, self.mode | fcntl.LOCK_NB)
        except BlockingIOError:
            self.logger.info(f"[TWO-CARD] waiting for {self.kind} lock {path} (other card)")
            fcntl.flock(self.fh, self.mode)
            self.logger.info(f"[TWO-CARD] {self.kind} lock acquired {path}")
        return self

    def __exit__(self, *exc) -> None:
        assert self.fh is not None
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()

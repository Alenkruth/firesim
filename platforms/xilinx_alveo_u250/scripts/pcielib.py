import os
import subprocess
import sys
import re
import time
from pathlib import Path

from typing import Dict, List

pciDevicesPath = Path('/sys/bus/pci/devices')

def get_device_paths(bus_id: str) -> List[Path]:
    result = []
    for entry in pciDevicesPath.iterdir():
        if re.match('^0000:' + re.escape(bus_id) + ':[a-fA-F0-9]{2}\.[0-7]$', entry.name):
            result.append(entry)
    return result

def get_device_extended_bdfs(bus_id: str) -> List[str]:
    return [e.name for e in get_device_paths(bus_id)]

def get_singular_device_path(bus_id: str) -> Path:
    devicePaths = get_device_paths(bus_id)
    if len(devicePaths) == 0:
        sys.exit(f":ERROR: Unable to obtain Extended Device BDF path for {bus_id}")
    if len(devicePaths) != 1:
        sys.exit(f":ERROR: Unable to obtain Extended Device BDF path for {bus_id} since too many Extended Device BDFs match: {devicePaths}")
    return devicePaths[0]

def get_singular_device_extended_bdf(bus_id: str) -> str:
    deviceBDFs = get_device_extended_bdfs(bus_id)
    if len(deviceBDFs) == 0:
        sys.exit(f":ERROR: Unable to obtain Extended Device BDF for {bus_id}")
    if len(deviceBDFs) != 1:
        sys.exit(f":ERROR: Unable to obtain Extended Device BDF for {bus_id} since too many Extended Device BDFs match: {deviceBDFs}")
    return deviceBDFs[0]

# obtain bridge paths/bdfs

def get_bridge_paths(bus_id: str) -> List[Path]:
    return [e.resolve().absolute().parent for e in get_device_paths(bus_id)]

def get_bridge_extended_bdfs(bus_id: str) -> List[str]:
    return [e.name for e in get_bridge_paths(bus_id)]

def get_singular_bridge_path(bus_id: str) -> Path:
    bridgePaths = get_bridge_paths(bus_id)
    if len(bridgePaths) == 0:
        sys.exit(f":ERROR: Unable to obtain Extended Bridge BDF path for {bus_id}")
    if len(bridgePaths) != 1:
        sys.exit(f":ERROR: Unable to obtain Extended Bridge BDF path for {bus_id} since too many Extended Bridge BDFs match: {bridgePaths}")
    return bridgePaths[0]

def get_singular_bridge_extended_bdf(bus_id: str) -> str:
    bridgeBDFs = get_bridge_extended_bdfs(bus_id)
    if len(bridgeBDFs) == 0:
        sys.exit(f":ERROR: Unable to obtain Extended Bridge BDF for {bus_id}")
    if len(bridgeBDFs) != 1:
        sys.exit(f":ERROR: Unable to obtain Extended Bridge BDF for {bus_id} since too many Extended Bridge BDFs match: {bridgeBDFs}")
    return bridgeBDFs[0]

# misc

def get_fpga_devs(bus_id) -> List[Path]:
    def readUevent(path: Path) -> Dict[str, str]:
        if not (path / 'uevent').exists():
            return {}
        return { entry[0]: entry[1] for entry in [line.strip('\n\r ').split('=') for line in open(f'{path}/uevent', 'r').readlines()] if len(entry) >= 2 }

    def xdmaResolver(path: Path) -> List[Path]:
        xdmaDevs = []
        for f in ['resource', 'resource0', 'resource1']:
            rsrcPath = (path / f)
            if rsrcPath.exists():
                xdmaDevs.append(rsrcPath)
        xdmaPath = (path / 'xdma')
        if xdmaPath.is_dir():
            ueventEntries = [readUevent(xdmaPath / entry.name) for entry in xdmaPath.iterdir() if (xdmaPath / entry.name).is_dir()]
            xdmaDevs.extend([Path('/dev') / uevent['DEVNAME'] for uevent in ueventEntries if 'DEVNAME' in uevent and (Path('/dev') / uevent['DEVNAME']).exists()])
        return xdmaDevs

    resolvers = {
        'xdma' : xdmaResolver
    }

    returnDevs = []
    fpgaDevices = get_device_extended_bdfs(bus_id)
    for fpgaDev in fpgaDevices:
        path = pciDevicesPath / fpgaDev
        fpgaDevUevent = readUevent(path)
        if 'DRIVER' not in fpgaDevUevent:
            print(":WARNING: Verify that 'xdma' driver is loaded")
            continue
        if fpgaDevUevent['DRIVER'] not in resolvers:
            continue
        returnDevs.extend(resolvers[fpgaDevUevent['DRIVER']](path.resolve()))

    return returnDevs

# clear SERR bit in command register
# https://support.xilinx.com/s/question/0D52E00006hpjPHSAY/dell-r720-poweredge-server-reboots-on-fpga-reprogramming?language=en_US
def clear_serr_bits(bus_id: str) -> None:
    for bridgeBDF in get_bridge_extended_bdfs(bus_id):
        run = subprocess.run(['setpci', '-s', bridgeBDF, 'COMMAND=0000:0100'])
        if run.returncode != 0:
            sys.exit(f":ERROR: Unable to clear SERR bit for {bridgeBDF}")
        time.sleep(1)

# clear fatal error reporting enable bit in the device control register
# https://support.xilinx.com/s/question/0D52E00006hpjPHSAY/dell-r720-poweredge-server-reboots-on-fpga-reprogramming?language=en_US
def clear_fatal_error_reporting_bits(bus_id: str) -> None:
    for bridgeBDF in get_bridge_extended_bdfs(bus_id):
        run = subprocess.run(['setpci', '-s', bridgeBDF, 'CAP_EXP+8.w=0000:0004'])
        if run.returncode != 0:
            sys.exit(f":ERROR: Unable to clear error reporting bit for {bridgeBDF}")
        time.sleep(1)

def write_to_linux_device_path(path: Path, data: str = '1\n') -> None:
    try:
        print(f":INFO: Writing to {path}: {data.strip()}")
        open(path, 'w').write(data)
    except:
        sys.exit(f":ERROR: Cannot write to {path} value: {data}")
    time.sleep(1)

def remove(bus_id: str) -> None:
    for devicePaths in get_device_paths(bus_id):
        removePath = devicePaths.resolve().absolute() / 'remove'
        if removePath.exists():
            write_to_linux_device_path(removePath)

# [TWO-CARD] card-scoped helpers (used only by firesim-fpga-util.py --card-scoped).
# The stock rescan() below derives the parent bridge from the device's sysfs entry,
# which no longer exists after remove(); its bridge loop is then empty and only the
# GLOBAL /sys/bus/pci/rescan (every root port, every card) re-adds the card.
# Card-scoped mode remembers the bridge BEFORE the remove and rescans only that root
# port's secondary bus (<rootport>/pci_bus/0000:<bus>, reached via the stable
# /sys/class/pci_bus/0000:<bus> link, which survives the endpoint's removal, so a
# standalone --reconnect-bdf --card-scoped also recovers a removed card).
pciBusClassPath = Path('/sys/class/pci_bus')
procPath = Path('/proc')
_bridge_cache: Dict[str, List[Path]] = {}
_bdf_re = re.compile(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$')

def remember_bridges(bus_id: str) -> None:
    bridges = get_bridge_paths(bus_id)
    if len(bridges) != 1:
        sys.exit(f":ERROR: expected exactly one parent bridge for {bus_id}, found {bridges}")
    _bridge_cache[bus_id] = bridges

def card_bus_rescan_path(bus_id: str) -> Path:
    """<rootport>/pci_bus/0000:<bus>/rescan; refuses a root bus (whose rescan would
    walk a whole host bridge) and a target that disagrees with the parent bridge
    remembered before the remove (or seen now, if the card is present)."""
    busLink = pciBusClassPath / f'0000:{bus_id}'
    if not busLink.exists():
        sys.exit(f":ERROR: {busLink} missing; refusing the global rescan (card-scoped)")
    busNode = busLink.resolve()
    owner = busNode.parent.parent  # .../<rootport>/pci_bus/0000:<bus> -> <rootport>
    if busNode.parent.name != 'pci_bus' or not _bdf_re.match(owner.name):
        sys.exit(f":ERROR: {busLink} -> {busNode} is not a bridge's secondary bus; refusing (card-scoped)")
    expected = _bridge_cache.get(bus_id) or get_bridge_paths(bus_id)
    if len(expected) > 1 or (len(expected) == 1 and expected[0].resolve() != owner):
        sys.exit(f":ERROR: {busLink} owner {owner} disagrees with parent bridge {expected}; refusing (card-scoped)")
    return busNode / 'rescan'

def rescan_card_scoped(bus_id: str) -> None:
    busRescan = card_bus_rescan_path(bus_id)
    if not busRescan.exists():
        sys.exit(f":ERROR: {busRescan} missing; refusing the global rescan (card-scoped)")
    write_to_linux_device_path(busRescan)
    if not any_device_exists(bus_id):
        sys.exit(f":ERROR: {bus_id} did not reappear after {busRescan}; refusing the global rescan (card-scoped)")

def card_device_nodes(bus_id: str) -> List[str]:
    """Paths whose open fd or mmap pins this card's xdma state: /dev/<name> for every
    entry under <dev>/xdma/ and the device's own sysfs resource* (BAR) files."""
    nodes = []
    for dev in get_device_paths(bus_id):
        real = dev.resolve()
        xdmaDir = real / 'xdma'
        if xdmaDir.is_dir():
            nodes.extend(str(Path('/dev') / e.name) for e in sorted(xdmaDir.iterdir()))
        nodes.extend(str(r) for r in sorted(real.glob('resource*')))
    return nodes

def card_node_holders(bus_id: str) -> Dict[str, List[str]]:
    """pid -> this card's nodes it holds open (fd) or mapped (maps). An unreadable
    /proc entry (other than a process exiting mid-scan) counts as a holder."""
    nodes = set(card_device_nodes(bus_id))
    holders: Dict[str, List[str]] = {}
    if not nodes:
        return holders
    for pdir in procPath.iterdir():
        if not pdir.name.isdigit():
            continue
        hit = set()
        try:
            for fd in (pdir / 'fd').iterdir():
                try:
                    tgt = os.readlink(fd)
                except FileNotFoundError:
                    continue
                if tgt.endswith(' (deleted)'):
                    tgt = tgt[:-len(' (deleted)')]
                if tgt in nodes:
                    hit.add(tgt)
            with open(pdir / 'maps') as f:
                for line in f:
                    parts = line.rstrip('\n').split(None, 5)
                    if len(parts) == 6:
                        p = parts[5]
                        if p.endswith(' (deleted)'):
                            p = p[:-len(' (deleted)')]
                        if p in nodes:
                            hit.add(p)
        except (FileNotFoundError, ProcessLookupError):
            continue  # process exited during the scan
        except PermissionError as e:
            hit.add(f"<unreadable: {e}>")
        if hit:
            holders[pdir.name] = sorted(hit)
    return holders

def refuse_if_card_held(bus_id: str, when: str) -> None:
    """Replaces rmmod's EBUSY refusal: the sysfs remove frees the device even while a
    process holds its /dev/xdmaN_* fds or BAR mmap."""
    holders = card_node_holders(bus_id)
    if holders:
        detail = "; ".join(f"pid {p}: {', '.join(n)}" for p, n in sorted(holders.items()))
        sys.exit(f":ERROR: [TWO-CARD] {when}: card bus {bus_id} is in use ({detail}). "
                 f"Refusing the sysfs remove / PCIe writes; stop those processes first (card-scoped)")

# masked write: set Memory Space Enable only, keep BusMaster/SERR# (and every other
# bit) that the xdma probe, which now runs inside the bus rescan, already set
def enable_memmapped_transfers_masked(bus_id: str) -> None:
    for deviceBDF in get_device_extended_bdfs(bus_id):
        run = subprocess.run(['setpci', '-s', deviceBDF, 'COMMAND=0002:0002'])
        if run.returncode != 0:
            sys.exit(f":ERROR: Unable to enable memmapped transfers on {deviceBDF}")
        time.sleep(1)

def rescan(bus_id: str) -> None:
    for bridgePath in get_bridge_paths(bus_id):
        rescanPath = bridgePath / 'rescan'
        if rescanPath.exists():
            write_to_linux_device_path(rescanPath)
    write_to_linux_device_path(Path('/sys/bus/pci/rescan'))

# enable memory mapped transfers for the fpga
# https://support.xilinx.com/s/question/0D52E00006iHlNoSAK/lspci-reports-bar-0-disabled?language=en_US
def enable_memmapped_transfers(bus_id: str) -> None:
    for deviceBDF in get_device_extended_bdfs(bus_id):
        run = subprocess.run(['setpci', '-s', deviceBDF, 'COMMAND=0x02'])
        if run.returncode != 0:
            sys.exit(f":ERROR: Unable to enable memmapped transfers on {deviceBDF}")
        time.sleep(1)

def any_device_exists(bus_id: str) -> bool:
    return len(get_device_paths(bus_id)) > 0

# converter funcs

def get_extended_bdf_from_bdf(bdf: str) -> str:
    return '0000:' + bdf

def get_bus_id_from_extended_bdf(extended_bdf: str) -> str:
    return extended_bdf[5:7]

def get_bdf_from_extended_bdf(extended_bdf: str) -> str:
    return extended_bdf[5:]

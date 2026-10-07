import argparse
import ctypes
import json
import sys
import uuid
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Adapter:
    device_id: int
    name: str
    device_instance_id: str


def select_adapter(instance_id: str, adapters: list[Adapter]) -> Adapter:
    if not instance_id or not instance_id.strip():
        raise ValueError("IMMICH_WINDOWS_ML_DEVICE_INSTANCE_ID is required for DirectML")
    matches = [adapter for adapter in adapters if adapter.device_instance_id.casefold() == instance_id.casefold()]
    if len(matches) != 1:
        raise ValueError(f"Expected one DirectML GPU matching {instance_id}; found {len(matches)}")
    return matches[0]


class Luid(ctypes.Structure):
    _fields_ = [("LowPart", ctypes.c_uint32), ("HighPart", ctypes.c_int32)]


class AdapterDesc(ctypes.Structure):
    _fields_ = [
        ("Description", ctypes.c_wchar * 128),
        ("VendorId", ctypes.c_uint32),
        ("DeviceId", ctypes.c_uint32),
        ("SubSysId", ctypes.c_uint32),
        ("Revision", ctypes.c_uint32),
        ("DedicatedVideoMemory", ctypes.c_size_t),
        ("DedicatedSystemMemory", ctypes.c_size_t),
        ("SharedSystemMemory", ctypes.c_size_t),
        ("AdapterLuid", Luid),
        ("Flags", ctypes.c_uint32),
    ]


class OpenAdapter(ctypes.Structure):
    _fields_ = [("pDeviceName", ctypes.c_wchar_p), ("hAdapter", ctypes.c_uint32), ("AdapterLuid", Luid)]


class CloseAdapter(ctypes.Structure):
    _fields_ = [("hAdapter", ctypes.c_uint32)]


def com_method(pointer, index, result, *arguments):
    table = ctypes.cast(pointer, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    return ctypes.WINFUNCTYPE(result, ctypes.c_void_p, *arguments)(table[index])


def check_status(status: int, operation: str) -> None:
    if status < 0:
        raise OSError(f"{operation} failed: 0x{status & 0xFFFFFFFF:08X}")


def adapter_luid(instance_id: str) -> tuple[int, int]:
    if not instance_id.strip():
        raise ValueError("IMMICH_WINDOWS_ML_DEVICE_INSTANCE_ID is required for DirectML")
    guid = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID("1ca05180-a699-450a-9a0c-de4fbe3ddd89").bytes_le)
    config = ctypes.WinDLL("cfgmgr32")
    size = config.CM_Get_Device_Interface_List_SizeW
    size.argtypes = [ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
    size.restype = ctypes.c_uint32
    get_list = config.CM_Get_Device_Interface_ListW
    get_list.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
    get_list.restype = ctypes.c_uint32
    remaining_attempts = 3
    while remaining_attempts:
        remaining_attempts -= 1
        length = ctypes.c_uint32()
        status = size(ctypes.byref(length), ctypes.byref(guid), instance_id, 0)
        if status:
            raise OSError(f"CM_Get_Device_Interface_List_SizeW failed: {status}")
        buffer = ctypes.create_unicode_buffer(length.value)
        status = get_list(ctypes.byref(guid), instance_id, buffer, length.value, 0)
        if status != 0x1A:
            break
    if status:
        raise OSError(f"CM_Get_Device_Interface_ListW failed: {status}")
    interfaces = [value for value in buffer[:].split("\x00") if value]
    if len(interfaces) != 1:
        raise ValueError(f"Expected one active GPU interface for {instance_id}; found {len(interfaces)}")
    gdi = ctypes.WinDLL("gdi32")
    opened = OpenAdapter(interfaces[0], 0, Luid())
    open_adapter = gdi.D3DKMTOpenAdapterFromDeviceName
    open_adapter.argtypes = [ctypes.POINTER(OpenAdapter)]
    open_adapter.restype = ctypes.c_int32
    close_adapter = gdi.D3DKMTCloseAdapter
    close_adapter.argtypes = [ctypes.POINTER(CloseAdapter)]
    close_adapter.restype = ctypes.c_int32
    check_status(open_adapter(ctypes.byref(opened)), "D3DKMTOpenAdapterFromDeviceName")
    try:
        return opened.AdapterLuid.LowPart, opened.AdapterLuid.HighPart
    finally:
        check_status(close_adapter(ctypes.byref(CloseAdapter(opened.hAdapter))), "D3DKMTCloseAdapter")


def enumerate_adapters(instance_id: str) -> list[Adapter]:
    if sys.platform != "win32":
        raise OSError("DirectML GPU selection requires Windows")
    target_luid = adapter_luid(instance_id)
    iid = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID("770aae78-f26f-4dba-a829-253c83d1b387").bytes_le)
    factory = ctypes.c_void_p()
    create = ctypes.WinDLL("dxgi").CreateDXGIFactory1
    create.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    create.restype = ctypes.c_int32
    check_status(create(ctypes.byref(iid), ctypes.byref(factory)), "CreateDXGIFactory1")
    adapters = []
    try:
        index = 0
        while True:
            adapter = ctypes.c_void_p()
            status = com_method(factory, 12, ctypes.c_int32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p))(
                factory, index, ctypes.byref(adapter)
            )
            if status & 0xFFFFFFFF == 0x887A0002:
                break
            check_status(status, "IDXGIFactory1.EnumAdapters1")
            try:
                desc = AdapterDesc()
                check_status(
                    com_method(adapter, 10, ctypes.c_int32, ctypes.POINTER(AdapterDesc))(adapter, ctypes.byref(desc)),
                    "IDXGIAdapter1.GetDesc1",
                )
                if not desc.Flags & 2 and (desc.AdapterLuid.LowPart, desc.AdapterLuid.HighPart) == target_luid:
                    adapters.append(Adapter(index, desc.Description, instance_id))
            finally:
                com_method(adapter, 2, ctypes.c_uint32)(adapter)
            index += 1
    finally:
        com_method(factory, 2, ctypes.c_uint32)(factory)
    return adapters


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instance-id", required=True)
    arguments = parser.parse_args()
    result = asdict(select_adapter(arguments.instance_id, enumerate_adapters(arguments.instance_id)))
    print(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)

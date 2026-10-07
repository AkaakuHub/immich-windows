import importlib.util
import sys
import unittest
from pathlib import Path


path = Path(__file__).resolve().parents[1] / "runtime" / "DirectML-Adapter.py"
spec = importlib.util.spec_from_file_location("directml_adapter", path)
adapter_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter_module
spec.loader.exec_module(adapter_module)
Adapter = adapter_module.Adapter
radeon_id = r"PCI\VEN_1002&DEV_699F&SUBSYS_17121028&REV_C7\4&34B30BE6&0&0008"
intel_id = r"PCI\VEN_8086&DEV_3E92&SUBSYS_085C1028&REV_00\3&11583659&0&10"


class AdapterSelectionTests(unittest.TestCase):
    def test_same_radeon_selected_after_adapter_order_changes(self):
        for index in (0, 1, 2):
            radeon = Adapter(index, "Radeon RX550/550 Series", radeon_id)
            intel = Adapter((index + 1) % 3, "Intel UHD Graphics 630", intel_id)
            self.assertEqual(adapter_module.select_adapter(radeon_id, [intel, radeon]), radeon)

    def test_equal_model_names_do_not_select_a_different_physical_gpu(self):
        target = Adapter(1, "Radeon RX550/550 Series", radeon_id)
        other = Adapter(0, target.name, radeon_id[:-4] + "0010")
        self.assertEqual(adapter_module.select_adapter(radeon_id, [other, target]), target)

    def test_instance_id_is_case_insensitive(self):
        target = Adapter(1, "Radeon RX550/550 Series", radeon_id)
        self.assertEqual(adapter_module.select_adapter(radeon_id.lower(), [target]), target)

    def test_missing_radeon_does_not_select_intel(self):
        with self.assertRaisesRegex(ValueError, "found 0"):
            adapter_module.select_adapter(radeon_id, [Adapter(0, "Intel UHD Graphics 630", intel_id)])

    def test_empty_id_does_not_select_gpu_zero(self):
        for value in ("", " "):
            with self.assertRaisesRegex(ValueError, "required"):
                adapter_module.select_adapter(value, [Adapter(0, "Radeon", radeon_id)])

    def test_duplicate_native_mapping_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "found 2"):
            adapter_module.select_adapter(radeon_id, [Adapter(0, "Radeon", radeon_id), Adapter(1, "Radeon", radeon_id)])



if __name__ == "__main__":
    unittest.main()

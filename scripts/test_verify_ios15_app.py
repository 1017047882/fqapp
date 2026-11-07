"""@brief Regression tests for the iOS 15 packaging gate, without Apple tools."""
import pathlib
import plistlib
import struct
import tempfile
import unittest

from verify_ios15_app import check_app, check_macho


def image(minimum=15, platform=2, cpu=0x0100000C):
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0) + struct.pack(
        '<6I', 0x32, 24, platform, minimum << 16, 0, 0)


class IOS15GateTests(unittest.TestCase):
    def test_arm64_ios15(self):
        self.assertEqual(check_macho(image(), (15, 0, 0)), (15, 0, 0))

    def test_fat_wrapper(self):
        for data in [image(), image(16), image(platform=7)]:
            fat = struct.pack('>2I', 0xCAFEBABE, 1) + struct.pack(
                '>5I', 0x0100000C, 0, 28, len(data), 0) + data
            if data == image():
                self.assertEqual(check_macho(fat, (15, 0, 0)), (15, 0, 0))
            else:
                with self.assertRaises(ValueError):
                    check_macho(fat, (15, 0, 0))

    def test_legacy_deployment_command(self):
        data = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
        data += struct.pack('<4I', 0x25, 16, 15 << 16, 0)
        self.assertEqual(check_macho(data, (15, 0, 0)), (15, 0, 0))

    def test_incompatible_images(self):
        for data in [image(16), image(platform=7), image(cpu=0x01000007),
                     image()[:40], image()[:32], b'not a binary']:
            with self.subTest(data=data), self.assertRaises(ValueError):
                check_macho(data, (15, 0, 0))

    def test_flutter_bundle_and_plugins(self):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory)
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'MinimumOSVersion': '15.0', 'CFBundleExecutable': 'Runner',
                'UIDeviceFamily': [1, 2]}))
            required = ['Runner', 'Frameworks/App.framework/App',
                        'Frameworks/Flutter.framework/Flutter']
            for relative in required:
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(image())
            self.assertEqual(len(check_app(app)['images']), 3)
            plugin = app / 'Frameworks/Plugin.framework/Plugin'
            plugin.parent.mkdir()
            plugin.write_bytes(image(16))
            with self.assertRaisesRegex(ValueError, 'Plugin'):
                check_app(app)
            plugin.write_bytes(image())
            (app / required[1]).write_bytes(b'invalid')
            with self.assertRaises(ValueError):
                check_app(app)
            (app / required[1]).unlink()
            with self.assertRaises(ValueError):
                check_app(app)


if __name__ == '__main__':
    unittest.main()

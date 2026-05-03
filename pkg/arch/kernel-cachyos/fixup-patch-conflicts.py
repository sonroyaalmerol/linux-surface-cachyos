#!/usr/bin/env python3
"""Fix known patch conflicts after CachyOS + Surface patches are applied."""

import sys

def fix_wants_ce_events():
    """Add TCP_CONG_WANTS_CE_EVENTS define if referenced but not defined."""
    try:
        with open("include/net/tcp.h", "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return

    has_ref = any("tcp_ca_wants_ce_events" in l for l in lines)
    has_define = any(l.strip().startswith("#define TCP_CONG_WANTS_CE_EVENTS") for l in lines)

    if has_ref and not has_define:
        for i, line in enumerate(lines):
            if line.startswith("#define TCP_CONG_NEEDS_ECN"):
                lines.insert(i + 1, "/* Wants notification of CE events (AccECN) */\n")
                lines.insert(i + 2, "#define TCP_CONG_WANTS_CE_EVENTS\tBIT(5)\n")
                break
        for j, ml in enumerate(lines):
            if ml.startswith("#define TCP_CONG_MASK"):
                lines[j] = "#define TCP_CONG_MASK\t(TCP_CONG_NON_RESTRICTED | TCP_CONG_NEEDS_ECN | TCP_CONG_WANTS_CE_EVENTS)\n"
                break
        with open("include/net/tcp.h", "w") as f:
            f.writelines(lines)
        print("  -> Fixed TCP_CONG_WANTS_CE_EVENTS define")


def fix_multitouch_close():
    """Fix orphaned SKIP_MODESET code after mt_on_hid_hw_close."""
    try:
        with open("drivers/hid/hid-multitouch.c", "r") as f:
            content = f.read()
    except FileNotFoundError:
        return

    # Pattern: close function with only mt_set_modes, then orphaned block
    broken_pattern = """static void mt_on_hid_hw_close(struct hid_device *hdev)
{
\tmt_set_modes(hdev, HID_LATENCY_HIGH, TOUCHPAD_REPORT_NONE);
}
\t/*
\t * Some devices (e.g. Surface Laptop Studio 2 touchpad) can get stuck
\t * non-functional if we change touchpad reporting modes from the HID
\t * open/close hooks. Avoid mode switching on hw_open/hw_close for
\t * those devices.
\t */
\tif (td && td->mtclass.quirks & MT_QUIRK_SKIP_MODESET_ON_HW_OPEN_CLOSE)
\t\treturn;"""

    fixed_close = """static void mt_on_hid_hw_close(struct hid_device *hdev)
{
\tstruct mt_device *td = hid_get_drvdata(hdev);

\t/*
\t * Some devices (e.g. Surface Laptop Studio 2 touchpad) can get stuck
\t * non-functional if we change touchpad reporting modes from the HID
\t * open/close hooks. Avoid mode switching on hw_open/hw_close for
\t * those devices.
\t */
\tif (td && td->mtclass.quirks & MT_QUIRK_SKIP_MODESET_ON_HW_OPEN_CLOSE)
\t\treturn;

\tif (td->mtclass.quirks & MT_QUIRK_KEEP_LATENCY_ON_CLOSE)
\t\tmt_set_modes(hdev, HID_LATENCY_NORMAL, TOUCHPAD_REPORT_NONE);
\telse
\t\tmt_set_modes(hdev, HID_LATENCY_HIGH, TOUCHPAD_REPORT_ALL);
}"""

    if broken_pattern in content:
        content = content.replace(broken_pattern, fixed_close)
        with open("drivers/hid/hid-multitouch.c", "w") as f:
            f.write(content)
        print("  -> Fixed mt_on_hid_hw_close function")


if __name__ == "__main__":
    print("Fixing known patch conflicts...")
    fix_wants_ce_events()
    fix_multitouch_close()
    print("Patch conflict fixup complete")

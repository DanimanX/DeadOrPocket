// DeadOrPocket Compute Cartridge — Parametric 3D-Printable Enclosure (OpenSCAD)
// Fits standard Analogue Pocket / Game Boy cartridge slot (5V sense shoulder preserved!)
// Print in PLA/PETG/Resin (0.16 mm layer height, no supports needed when laid flat).

$fn = 36;

// External Cartridge Dimensions (mm)
cart_w        = 60.5;   // Fits 61.0 mm Pocket cartridge bay cleanly
cart_lower_h  = 39.0;   // Portion inserted inside Analogue Pocket slot
cart_upper_h  = 40.0;   // Extended upper housing above Pocket top lip (like GB Camera)
cart_total_h  = cart_lower_h + cart_upper_h; // 79.0 mm total
cart_lower_t  = 7.8;    // Standard GB/GBC cartridge thickness (keeps 5V sense switch active!)
cart_upper_t  = 11.5;   // Extra headroom above Pocket for BGA heatsink + USB-C + MicroSD
wall          = 1.6;
pcb_t         = 1.0;

module half_shell(is_front = true) {
    difference() {
        union() {
            // Lower slot tongue (standard GB/GBC 5V geometry - NO GBA notch!)
            cube([cart_w, cart_lower_h, cart_lower_t / 2]);
            // Upper electronics housing (slightly thicker on rear side to clear Pocket back)
            translate([0, cart_lower_h - 1.0, 0])
                cube([cart_w, cart_upper_h + 1.0, is_front ? (cart_lower_t / 2) : (cart_upper_t - cart_lower_t / 2)]);
        }
        // Inner PCB cavity
        translate([wall, 12.0, wall])
            cube([cart_w - 2*wall, cart_total_h - 12.0 - wall, 12.0]);
        // Bottom 32-pin gold edge finger opening
        translate([3.5, -0.5, wall])
            cube([cart_w - 7.0, 13.0, 10.0]);
        // Side USB-C Auxiliary Power Cutout (Right side, y = 45 mm)
        translate([cart_w - wall - 1.0, 41.0, wall])
            cube([wall + 2.0, 9.6, 4.0]);
        // Side MicroSD Card Slot Cutout (Left side, y = 62 mm)
        translate([-1.0, 55.5, wall])
            cube([wall + 2.0, 14.0, 2.6]);
        // Recessed Tactile Reset Pinhole (Right side, y = 56 mm)
        translate([cart_w - wall - 1.0, 56.0, 3.0])
            rotate([0, 90, 0]) cylinder(h = wall + 2.0, d = 2.2);
        // 4 Diagnostic LED Light-Pipe Windows (Top edge, front half only)
        if (is_front) {
            for (i = [0:3]) {
                translate([22.0 + i*5.0, cart_total_h - 5.5, -0.5])
                    cylinder(h = wall + 1.0, d = 2.0);
            }
        }
        // M2.5 screw bosses through-holes
        for (mx = [7.5, cart_w - 7.5]) {
            translate([mx, 35.5, -0.5]) cylinder(h = 15.0, d = is_front ? 2.6 : 2.1);
        }
    }
}

// Render front & back halves side-by-side ready for slicing
translate([0, 0, 0])          half_shell(true);
translate([cart_w + 8, 0, 0]) half_shell(false);

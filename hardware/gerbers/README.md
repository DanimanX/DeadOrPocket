# DeadOrPocket Compute Cartridge (Rev A) — PCB Fabrication Files

This directory contains the production-ready RS-274X Extended Gerber and Excellon NC Drill files for the **DeadOrPocket Sega Model 2 & Model 2A-CRX Compute Cartridge**.

### PCB Specifications
- **Dimensions:** 57.500 mm × 76.000 mm (Tongue: 52.000 mm × 12.000 mm)
- **Thickness:** **1.0 mm** (±10%) — **Mandatory for Analogue Pocket cartridge slot fit**
- **Layer Count:** **6 Layers** (JLC06101H-3313 standard stackup or equivalent)
- **Surface Finish:** **ENIG (Electroless Nickel Immersion Gold)** — **Mandatory for gold edge fingers**
- **Edge Connector:** **30° Chamfer / Bevel** (Depth 1.0 mm) on 32 ENIG gold fingers (1.50 mm pitch)
- **Solder Mask:** Green (or Matte Black)
- **Silkscreen:** White
- **Minimum Trace / Clearance:** 5 mil / 5 mil (0.127 mm / 0.127 mm)
- **Minimum Drill:** 0.20 mm (Micro via) / 0.40 mm pad annular

### Layer Mapping Table
| Filename | Type | Description |
|---|---|---|
| `DeadOrPocket_Cartridge_RevA-F_Cu.gtl` | RS-274X | Layer 1: Top Copper (SMD pads, escape tracks, series bus) |
| `DeadOrPocket_Cartridge_RevA-In1_Cu.g2` | RS-274X | Layer 2: Inner GND Solid Plane |
| `DeadOrPocket_Cartridge_RevA-In2_Cu.g3` | RS-274X | Layer 3: Inner High-Speed Bus (SDRAM length-matched + Pocket bus) |
| `DeadOrPocket_Cartridge_RevA-In3_Cu.g4` | RS-274X | Layer 4: Inner Split Power Planes (1.10V VCCINT, 2.50V VCCA, 3.30V VCCIO, 5.0V SYS) |
| `DeadOrPocket_Cartridge_RevA-In4_Cu.g5` | RS-274X | Layer 5: Inner GND2 Solid Plane |
| `DeadOrPocket_Cartridge_RevA-B_Cu.gbl` | RS-274X | Layer 6: Bottom Copper (SOIC-8 Flash, MicroSD, JTAG, Decoupling) |
| `DeadOrPocket_Cartridge_RevA-F_Mask.gts` | RS-274X | Top Solder Mask |
| `DeadOrPocket_Cartridge_RevA-B_Mask.gbs` | RS-274X | Bottom Solder Mask |
| `DeadOrPocket_Cartridge_RevA-F_Silks.gto` | RS-274X | Top Silkscreen Legend & Component Outlines |
| `DeadOrPocket_Cartridge_RevA-B_Silks.gbo` | RS-274X | Bottom Silkscreen Legend & Pinout |
| `DeadOrPocket_Cartridge_RevA-F_Paste.gtp` | RS-274X | Top Solder Paste Stencil |
| `DeadOrPocket_Cartridge_RevA-B_Paste.gbp` | RS-274X | Bottom Solder Paste Stencil |
| `DeadOrPocket_Cartridge_RevA-Edge_Cuts.gm1` | RS-274X | Mechanical Board Outline & 30° Gold Finger Chamfer Note |
| `DeadOrPocket_Cartridge_RevA-PTH.drl` | Excellon | Plated Through-Hole Drill File (0.20 mm vias, 0.65 mm shield posts) |
| `DeadOrPocket_Cartridge_RevA-NPTH.drl` | Excellon | Non-Plated Through-Hole Drill File (2× 2.50 mm shell mounting holes) |
| `DeadOrPocket_Cartridge_RevA-job.gbrjob` | JSON | Gerber Job / Stackup Metadata specification |

### Assembly Files
- **Bill of Materials (BOM):** [`hardware/bom_jlcpcb.csv`](../bom_jlcpcb.csv)
- **Pick-and-Place CPL:** [`hardware/cpl_jlcpcb.csv`](../cpl_jlcpcb.csv)
- **3D Shell (OpenSCAD):** [`hardware/shell/deadorpocket_cart_shell.scad`](../shell/deadorpocket_cart_shell.scad)

### Ordering on JLCPCB
1. Upload `DeadOrPocket_Cartridge_RevA_Gerbers.zip` directly to [jlcpcb.com](https://jlcpcb.com/quote).
2. Select:
   - **Layers:** 6
   - **Dimensions:** 57.5 × 76.0 mm
   - **PCB Thickness:** **1.0 mm** (Select JLC06101H-3313 stackup)
   - **Surface Finish:** **ENIG**
   - **Gold Fingers:** **Yes** (30° chamfer angle)
3. For SMT Assembly:
   - Upload `hardware/bom_jlcpcb.csv` and `hardware/cpl_jlcpcb.csv`.

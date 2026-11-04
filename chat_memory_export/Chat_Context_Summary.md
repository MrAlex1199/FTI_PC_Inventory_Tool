# FTI PC Inventory Tool - Conversation & Memory Handoff Document
**Session ID**: `b0d6b9ba-cb3c-419f-aa80-cedd90a17c21`  
**Date**: 2026-11-03  
**Project**: FTI PC Inventory Tool (`FTI_PC_Inventory.exe`)  
**Repository**: [MrAlex1199/FTI_PC_Inventory_Tool](https://github.com/MrAlex1199/FTI_PC_Inventory_Tool) (Branch: `main`)  
**Latest Build**: `v2026.11.03.5 Enterprise` (Authenticode SHA256 Signed)

---

## 1. Executive Summary & Current State of the Codebase

### A. โครงสร้างระบบหลัก (Architecture)
1. **Host Launcher (`src/host/Program.cs`)**:
   - Native C# WinExe Launcher (.NET 4.8 / 4.7.2) รันด้วย UAC Administrator (`app.manifest`)
   - รัน WebView2 / Edge Chromium Embedded ในตัว
2. **Backend Engine (`src/AppServer.ps1`)**:
   - HTTP Listener Localhost จัดการ REST API (`/api/status`, `/api/scan`, `/api/schedule`, `/api/master/*`, ฯลฯ)
   - Background Runspace รันสแกนคู่ขนาน และอ่าน Stream ส่งข้อมูลสดให้หน้าบ้าน
3. **Core Scanner (`src/Get-PCInventory.Core.ps1`)**:
   - ตรวจจับฮาร์ดแวร์ + ซอฟต์แวร์ผ่าน WMI / CIM / WinRM / Registry Click-to-Run
   - รองรับ Multi-Method Reachability: ICMP Ping, TCP Parallel Port Probing (135, 445, 5985, 3389), UDP/ARP
   - ผสานข้อมูลลง `Hardware_Master.csv`, `Software_Master.csv`, และ Snapshot CSV
4. **Web UI (`src/web/index.html`)**:
   - ออกแบบตามมาตรฐาน **UI/UX Pro Max** (Glassmorphism, High-contrast dark theme)
   - 3 แท็บหลัก:
     1. `🖥️ Hardware Scan`: ตารางสเปกสด พร้อมระบบยืด/หดคอลัมน์แบบ Excel (Drag to resize, Auto-fit, Reset Widths)
     2. `📦 Software Scan`: ตารางซอฟต์แวร์พร้อม Modal เจาะดูซอฟต์แวร์รายเครื่อง
     3. `📊 Dashboard`: แดชบอร์ดสรุปภาพรวมสินทรัพย์ 4 โซน พร้อมกราฟโต้ตอบ (Interactive Drill-down) และปุ่มพิมพ์รายงาน PDF

---

## 2. ฟีเจอร์ล่าสุดที่พัฒนาสำเร็จใน Session นี้

1. **คอลัมน์ `METHOD` ในตาราง Hardware**:
   - เพิ่มต่อจากคอลัมน์ `STATUS` ทันที แสดงช่องทางเชื่อมต่อ เช่น `ICMP Ping`, `TCP:135`, `TCP:445`, `WinRM:5985`, `Localhost`, หรือ `Offline`
   - บันทึกถาวรลงใน `Hardware_Master.csv`
2. **แก้ไขการตรวจจับ Office 2021 ESD ที่เคยแสดงเป็น 2016**:
   - สลับลำดับการตรวจจับจากเวอร์ชันใหม่ไปเก่า (`2024` -> `2021` -> `2019` -> `2016`) ป้องกัน Prefix `Office 16, Office21...` ของ Microsoft แมตช์ผิด
   - ตรวจจับ Edition ชัดเจน เช่น `2021 H&B Retail`, `2021 Pro Retail`
3. **ระบบยืด/ขยายคอลัมน์แบบ Excel (Live Interactive Column Resizer)**:
   - คลิกขอบหัวตารางแล้วลากปรับขนาดได้อิสระ พร้อมเส้นนำทางสีฟ้า (Guideline)
   - ดับเบิลคลิกเพื่อ Auto-fit พอดีข้อความ
   - จดจำค่าผ่าน `localStorage` ปิดเปิดใหม่ขนาดคงเดิม พร้อมปุ่ม `Reset Widths`
4. **แท็บ `📊 Dashboard` (Executive IT Asset Analytics)**:
   - **Zone 1: Executive KPI Cards**: Availability, Health Score Ring (%), License Compliance Rate, Upgrade Attention, Dominant Reachability
   - **Zone 2: Hardware Analytics**: Dual-Mode CPU Breakdown (By Tier vs By Gen/Win11 Readiness), RAM Distribution (Total GB), OS & Win 11 Readiness, Brand Distribution
   - **Zone 3: Software & Network**: Office Edition Matrix, Department (OU) vs IP Subnet Distribution
   - **Zone 4: Actionable Watchlist**: Critical Storage (C: ≤ 15%), Low RAM (< 8GB), License/Reachability Attention
   - **Interactive Drill-down**: คลิกที่แท่งกราฟหรือ Watchlist เพื่อสลับไปกรองตาราง Hardware ทันที
   - **Instant Preload**: โหลด Master DB เก่าขึ้นแดชบอร์ดทันทีที่เปิดแอป
   - **Print / PDF**: ปุ่มพิมพ์รายงานสรุปผู้บริหารแบบ A4 สะอาด คมชัด
5. **บันทึกกฎ Post-Build Git Push ถาวรใน [GEMINI.md](file:///e:/WEB/FTI_PC_Inventory_Tool/GEMINI.md)**:
   - กำหนดให้ระบบ Build ทำการ Stage, Commit, และ Push ขึ้น GitHub (`origin main`) โดยอัตโนมัติทุกครั้ง

---

## 3. วิธีนำ Session / Memory นี้ไปคุยต่อที่เครื่องอื่น

### วิธีที่ 1: ใช้ Git Repo + `GEMINI.md` (วิธีที่สะดวกและแนะนำที่สุด ⭐)
เนื่องจากเราได้บันทึกความจำ กฎเกณฑ์ สถาปัตยกรรม และโค้ดล่าสุดไว้ใน GitHub แล้ว:
1. ที่เครื่องอื่นของคุณ ให้เปิด Terminal แล้ว Clone โปรเจกต์:
   ```bash
   git clone https://github.com/MrAlex1199/FTI_PC_Inventory_Tool.git
   cd FTI_PC_Inventory_Tool
   ```
2. เปิด Antigravity หรือเครื่องมือ AI Coding Assistant (เช่น Claude, Gemini Code Assist, ChatGPT, Cursor)
3. พิมพ์แจ้ง AI ในบทสนทนาแรกว่า:
   > *"อ่านไฟล์ `GEMINI.md` และ `chat_memory_export/Chat_Context_Summary.md` เพื่อเข้าใจบริบทและคุยต่องานจาก Session เดิมได้เลย"*
   AI จะเข้าใจโปรเจกต์ กฎระเบียบ และสถานะล่าสุด 100% ทันที

---

### วิธีที่ 2: ย้ายไฟล์ Database และ Brain ของ Antigravity ข้ามเครื่อง (Native Continuation)
หากเครื่องปลายทางติดตั้ง **Google Antigravity** เช่นเดียวกัน และคุณต้องการให้แสดงเป็นแท็บแชทเดิมใน History:
1. คัดลอกไฟล์ในโฟลเดอร์ `chat_memory_export/` ไปยังเครื่องใหม่:
   - ไฟล์ฐานข้อมูล:
     - `b0d6b9ba-cb3c-419f-aa80-cedd90a17c21.db`
     - `b0d6b9ba-cb3c-419f-aa80-cedd90a17c21.db-shm`
     - `b0d6b9ba-cb3c-419f-aa80-cedd90a17c21.db-wal`
     นำไปวางไว้ที่โฟลเดอร์:
     `C:\Users\<ชื่อผู้ใช้ของคุณ>\.gemini\antigravity\conversations\`
   - ไฟล์แตกโฟลเดอร์สมอง (Brain):
     แตกไฟล์ `antigravity_brain_b0d6b9ba.zip` ไปไว้ที่:
     `C:\Users\<ชื่อผู้ใช้ของคุณ>\.gemini\antigravity\brain\b0d6b9ba-cb3c-419f-aa80-cedd90a17c21\`
2. เปิดโปรแกรม Antigravity ขึ้นมาใหม่ คุณจะเห็นประวัติการสนทนา Session นี้โผล่ขึ้นมาในรายการ และสามารถพิมพ์คุยต่อได้ทันที


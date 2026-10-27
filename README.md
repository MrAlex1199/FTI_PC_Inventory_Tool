# FTI PC Inventory Tool (Enterprise Edition v2.5)

โปรแกรมตรวจสอบและบันทึกข้อมูล **Hardware** และ **Software ที่ติดตั้ง** ของเครื่อง PC ในโดเมนองค์กร (~200 เครื่องขึ้นไป) ในรูปแบบหน้าต่าง **Windows GUI** ทรงพลัง (.exe) ใช้งานง่าย รองรับระบบ **ฐานข้อมูลหลัก Master Database สะสมรอบสแกน**, **ตั้งเวลาสแกนอัตโนมัติ (Task Scheduler & In-App Countdown)**, **สแกนซ้ำเฉพาะเครื่องที่ออฟไลน์**, และออกรายงานเป็นไฟล์ **CSV** รวมทั้ง **HTML Dashboard แบบแยกกล่องรายเครื่อง**

---

## 🌟 ฟีเจอร์เด่นระดับ Enterprise

1. **ฐานข้อมูลหลักสะสมข้อมูล (Master Database - `Hardware_Master.csv`)**:
   - อัปเดตข้อมูลเครื่องเดิมโดยไม่ลบทิ้ง (Upsert) พร้อมเก็บบันทึกประวัติ `First_Seen`, `Last_Scan`
   - มีคอลัมน์ **`Scan_Count`** นับจำนวนครั้งที่เครื่องนี้เคยถูกสแกนสำเร็จ
   - หากเครื่องใดเคยสแกนผ่านแล้ว ต่อมาปิดเครื่อง (Offline) ระบบจะแสดงสถานะ `Offline (Was OK)` และคงสเปกฮาร์ดแวร์เดิมไว้ ไม่กลายเป็นค่าว่าง
   - บันทึกไฟล์ประวัติแยกตามวันเวลา (`Hardware_YYYYMMDD_HHmm.csv`) ควบคู่กับ Master File เสมอ

2. **ระบบตั้งเวลาสแกนอัตโนมัติ (Automated Scheduling)**:
   - **In-App Timer Countdown**: ตั้งเวลานับถอยหลังภายในแอป (เช่น ทุก 1, 2, 4, 8, 12, 24 ชม.) สแกนรอบใหม่อัตโนมัติพร้อมแถบแสดงเวลานับถอยหลัง
   - **Windows Task Scheduler Integration**: ฝังคิวงานลง Task Scheduler ของ Windows ได้โดยตรงด้วยสิทธิ์ Admin รันสแกนเบื้องหลังแบบไร้หน้าต่าง (`-Silent`) ตามเวลาที่กำหนดทุกวัน

3. **สแกนซ้ำเฉพาะเครื่องที่ออฟไลน์ (Retry Offline PCs Only)**:
   - ตรวจจับจำนวนเครื่องที่ยังติดต่อไม่ได้ (`Offline` / `Error`) จากรอบก่อนหน้าโดยอัตโนมัติ
   - มีปุ่ม **"สแกนซ้ำเฉพาะเครื่องที่ออฟไลน์"** บนแถบควบคุม ช่วยประหยัดเวลา ไม่ต้องสแกนเครื่องที่ผ่านแล้วซ้ำอีก

4. **ตรวจจับข้อมูลฮาร์ดแวร์และ Active Directory เชิงลึก**:
   - **เวลาเปิดเครื่องล่าสุด & Uptime**: อ่านค่า `Win32_OperatingSystem.LastBootUpTime` และคำนวณ Uptime รายวัน/ชั่วโมง
   - **พื้นที่ว่างไดรฟ์ C: (Disk Free Space)**: แสดงขนาดคงเหลือ / ขนาดทั้งหมด / เปอร์เซ็นต์ พร้อมแถบเตือนสีแดงหากเหลือน้อยกว่า 15%
   - **AD Last Logon Timestamp**: อ่านเวลาเข้าสู่ระบบโดเมนล่าสุดของเครื่องจาก Active Directory
   - **AD OU Hierarchy**: แสดงโครงสร้างหน่วยงาน OU ย้อนจากระดับล่างขึ้นบน อ่านง่าย ชัดเจน

5. **Modern Cyber Slate Glassmorphism UI**:
   - หน้าต่างแอปสไตล์กระจกเงาคมชัด รองรับ Dark Mode และ Light Mode
   - วงแหวนความคืบหน้า (Progress Ring) และการ์ดสรุปสถิติ 4 มิติ
   - **Live Results Data Grid 12 คอลัมน์**: ค้นหาด่วน (Instant Search) และปุ่มกรองสถานะแบบไดนามิก

6. **Native C# Executable & Authenticode Signed (Non-Malware Flagged)**:
   - คอมไพล์ด้วย .NET Framework C# Native Compiler (`csc.exe`) แทนเครื่องมือแปลงสคริปต์ทั่วไป
   - ฝัง Application Manifest บังคับสิทธิ์ Admin (`requireAdministrator`) และ PerMonitorV2 High-DPI
   - ลงนามลายเซ็นดิจิทัล **Authenticode Digital Signature (SHA256)** องค์กร FTI พร้อมตัวติดตั้งใบรับรองคลิกเดียว (`Install_Certificate.bat`) ป้องกันการแจ้งเตือน Antivirus / Windows SmartScreen

---

## 📁 โครงสร้างโปรเจกต์

```text
FTI_PC_Inventory_Tool/
├── src/
│   ├── Get-PCInventory.Core.ps1   # ตรรกะการสแกนฮาร์ดแวร์ ซอฟต์แวร์ และผสาน Master DB
│   ├── AppServer.ps1              # เอนจิน HTTP Server เบื้องหลัง + เชื่อมต่อ Edge App + Task Scheduler API
│   ├── web/
│   │   └── index.html             # ส่วนติดต่อผู้ใช้ Cyber Slate Glassmorphism (HTML5/CSS/JS)
│   └── host/
│       ├── Program.cs             # Native C# Host Launcher (.NET 4.8 / 4.7.2)
│       └── app.manifest           # Windows Application Manifest (Admin UAC + DPI Aware)
├── build.ps1                      # สคริปต์คอมไพล์ Native C# + สร้างไอคอน + ลงนาม Authenticode
├── run.bat                        # สคริปต์คลิกเดียวสำหรับเปิดโปรแกรมทันที
├── push_to_github.bat             # ซิงค์โค้ดและส่งขึ้น GitHub อัตโนมัติ
├── dist/                          # ผลลัพธ์ไฟล์ .exe, ใบรับรอง .cer, และสคริปต์ติดตั้งใบรับรอง
└── README.md                      # คู่มือการใช้งาน
```

---

## 🚀 วิธีการใช้งาน

### วิธีที่ 1: เปิดใช้งานผ่าน `run.bat` (สะดวกที่สุด)
- ดับเบิ้ลคลิกไฟล์ `run.bat` ในโฟลเดอร์โปรเจกต์ โปรแกรมจะเรียกใช้งานแอปพลิเคชันเวอร์ชันล่าสุดทันที

### วิธีที่ 2: นำไฟล์ `.exe` ไปใช้งานบนเครื่อง Admin
1. ดับเบิ้ลคลิก `Install_Certificate.bat` (คลิกขวา Run as administrator) เพื่อติดตั้งใบรับรองความปลอดภัย FTI Enterprise
2. ดับเบิ้ลคลิกไฟล์ `FTI_PC_Inventory.exe` เพื่อเปิดใช้งาน (โปรแกรมจะขอสิทธิ์ Administrator อัตโนมัติ)

### การตั้งเวลาสแกนอัตโนมัติ (Scheduler):
1. ในหน้าต่างโปรแกรม ให้กดปุ่ม **"ตั้งเวลาสแกน"** (หรือที่การ์ดแถบซ้าย)
2. **โหมดนับถอยหลังในแอป**: เลือกช่วงเวลา (เช่น ทุก 2 ชม.) แล้วกด "เริ่มนับถอยหลัง"
3. **โหมด Windows Task Scheduler**: กำหนดเวลาสแกนประจำวัน (เช่น 08:30 น.) แล้วกด "บันทึกคิวงาน Windows" เครื่องจะรันสแกนเบื้องหลังอัตโนมัติแม้ปิดหน้าต่างโปรแกรมไปแล้ว

---

## 📋 ไฟล์ผลลัพธ์ที่ได้รับ (ในโฟลเดอร์ปลายทาง เช่น `C:\Inventory`)

| ชื่อไฟล์ | คำอธิบาย |
|---|---|
| `Hardware_Master.csv` | **ฐานข้อมูลหลักสะสมข้อมูล**: รวมสเปกเครื่องทั้งหมด พร้อม `Scan_Count`, `First_Seen`, `Last_Scan` |
| `Hardware_<วันเวลา>.csv` | สแนปช็อตข้อมูลสเปกเครื่องเฉพาะรอบการสแกนนั้นๆ |
| `Software_<วันเวลา>.csv` | รายละเอียดซอฟต์แวร์ทั้งหมดที่ตรวจพบในทุกเครื่อง |
| `Software_Summary_<วันเวลา>.csv` | สรุปแต่ละโปรแกรมและเวอร์ชันว่ามีติดตั้งอยู่กี่เครื่องในองค์กร |
| `Software_PerPC_<วันเวลา>.csv` | สรุปรายชื่อโปรแกรมทั้งหมดของแต่ละเครื่อง (1 แถวต่อ 1 เครื่อง) |
| `Software_ByPC_<วันเวลา>.html` | รายงานเว็บสวยงาม แยกกล่องค้นหารายเครื่อง เปิดใน Chrome/Edge ได้ทันที |
| `Software_ScanStatus_<วันเวลา>.csv` | สถานะการสแกนของแต่ละเครื่อง (`OK-WinRM`, `OK-DCOM`, `Offline`, `Error`) |

---

## 🛠️ วิธีการคอมไพล์ใหม่ (Build)

1. เปิด PowerShell (Run as administrator)
2. ไปที่โฟลเดอร์โปรเจกต์ และสั่งรัน:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\build.ps1
   ```
3. ตัวสร้างไฟล์จะคอมไพล์ C# Native Binary พร้อมเซ็นลายเซ็นดิจิทัล SHA256 และส่งมอบไปยังโฟลเดอร์ `dist\` และ `%LOCALAPPDATA%\FTI_PC_Inventory_Tool\dist\`


local writeCode = core.writeCode
local scanForAOB = core.scanForAOB

writeCode(scanForAOB("E8 ? ? ? ? 85 C0 74 19 A1 ? ? ? ? 69 C0 90 04 00 00 5F 5E 5D 66 C7 80 ? ? ? ? 03 00 5B C3")+30, {0x01})
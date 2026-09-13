void FUN_00025490(ulonglong param_1,ulonglong param_2,uint param_3)
{
  ulonglong uVar1;
  char cVar2;
  int iVar3;
  ulonglong uVar4;
  longlong lVar5;
  char *pcVar6;
  int iVar7;
  undefined1 auStack_128 [4];
  undefined4 local_124;
  undefined8 local_100;
  undefined8 uStack_f8;
  undefined8 uStack_f0;
  undefined8 uStack_e8;
  undefined8 local_e0;
  undefined8 uStack_d8;
  undefined8 uStack_d0;
  undefined8 uStack_c8;
  longlong local_c0;
  undefined8 local_b0;
  undefined8 uStack_a8;
  undefined8 local_a0;
  undefined8 uStack_98;
  undefined8 local_90;
  undefined8 uStack_88;
  undefined8 uStack_80;
  undefined8 uStack_78;
  ulonglong local_70;
  longlong local_68;
  
  local_68 = DAT_0023fe10;
  local_70 = 0;
  local_c0 = 0;
  uStack_88 = 0;
  local_90 = 0;
  uStack_78 = 0;
  uStack_80 = 0;
  uStack_98 = 0;
  local_a0 = 0;
  uStack_a8 = 0;
  local_b0 = 0;
  uStack_d8 = 0;
  local_e0 = 0;
  uStack_c8 = 0;
  uStack_d0 = 0;
  uStack_f8 = 0;
  local_100 = 0;
  uStack_e8 = 0;
  uStack_f0 = 0;
  if (param_3 == 0) {
    cVar2 = FUN_00038260();
    if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x80000000), cVar2 != '\0')) {
      pcVar6 = "DTB offset is NULL\n";
LAB_000256b8:
      FUN_00037d9c(0x80000000,pcVar6);
    }
  }
  else if ((ulonglong)param_3 <= ~param_1) {
    uVar1 = param_1 + (param_2 & 0xffffffff);
    param_1 = param_1 + param_3;
    if (param_1 + 0x28 < uVar1) {
      iVar7 = 0;
      do {
        (**(code **)(DAT_00260138 + 0x160))(auStack_128,param_1,0x28);
        uVar4 = FUN_0003832c(local_124);
        uVar4 = uVar4 & 0xffffffff;
        iVar3 = FUN_00036c38(auStack_128);
        if ((((iVar3 != 0) || (iVar3 = FUN_00027788(auStack_128), iVar3 != 0)) ||
            (CARRY8(param_1,uVar4))) || (uVar1 < param_1 + uVar4)) break;
        local_70 = param_1;
        cVar2 = FUN_00025700(&local_b0,&local_100,0x1d);
        if (cVar2 != '\0') {
          DAT_0023fe28 = iVar7;
        }
        if (uStack_78._4_4_ == 0) {
          cVar2 = FUN_00033740(param_1);
          if (((cVar2 == '\0') && (cVar2 = FUN_00038260(), cVar2 != '\0')) &&
             (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"Error while DTB parsing RTIC prop continue with next DTB\n");
          }
        }
        else if (((uStack_78._4_4_ ^ 0xffffffff) & 0x34150000) == 0) {
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"Exact DTB match found. DTBO search is not required\n");
          }
          DAT_00255278 = 1;
        }
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          FUN_00037d9c(0x400000,"Bestmatch = %x\n",uStack_c8._4_4_);
        }
        param_1 = param_1 + uVar4;
        iVar7 = iVar7 + 1;
      } while (param_1 + 0x28 < uVar1);
      lVar5 = local_c0;
      if (local_c0 != 0) goto LAB_000256c4;
    }
    cVar2 = FUN_00038260();
    if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x80000000), cVar2 != '\0')) {
      pcVar6 = "No match found for Soc Dtb type\n";
      goto LAB_000256b8;
    }
  }
  lVar5 = 0;
LAB_000256c4:
  if (DAT_0023fe10 != local_68) {
                    /* WARNING: Subroutine does not return */
    FUN_0001e34c(lVar5);
  }
  return;
}

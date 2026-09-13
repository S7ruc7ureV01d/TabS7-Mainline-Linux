void FUN_00026748(undefined8 param_1,ulonglong param_2)
{
  char cVar1;
  char cVar2;
  uint uVar3;
  int iVar4;
  ulonglong uVar5;
  longlong lVar6;
  char *pcVar7;
  uint uVar8;
  undefined4 *puVar9;
  undefined8 local_e0;
  undefined8 uStack_d8;
  undefined8 uStack_d0;
  undefined8 uStack_c8;
  undefined8 local_c0;
  undefined8 uStack_b8;
  undefined8 uStack_b0;
  undefined8 uStack_a8;
  longlong local_a0;
  undefined8 local_90;
  undefined8 uStack_88;
  undefined8 uStack_80;
  undefined8 uStack_78;
  undefined8 local_70;
  undefined8 uStack_68;
  undefined8 uStack_60;
  undefined8 uStack_58;
  longlong local_50;
  longlong local_48;
  
  local_48 = DAT_0023fe10;
  local_50 = 0;
  local_a0 = 0;
  uStack_68 = 0;
  local_70 = 0;
  uStack_58 = 0;
  uStack_60 = 0;
  uStack_88 = 0;
  local_90 = 0;
  uStack_78 = 0;
  uStack_80 = 0;
  uStack_b8 = 0;
  local_c0 = 0;
  uStack_a8 = 0;
  uStack_b0 = 0;
  uStack_d8 = 0;
  local_e0 = 0;
  uStack_c8 = 0;
  uStack_d0 = 0;
  if (param_2 == 0) {
    cVar1 = FUN_00038260();
    if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
      pcVar7 = "Dtbo Img buffer is NULL\n";
LAB_00026970:
      FUN_00037d9c(0x80000000,pcVar7);
    }
  }
  else {
    uVar5 = FUN_0003832c(*(undefined4 *)(param_2 + 0x14));
    uVar5 = uVar5 & 0xffffffff;
    if (~uVar5 < param_2) {
      cVar1 = FUN_00038260();
      if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
        pcVar7 = "Integer overflow deteced with Dtbo address\n";
        goto LAB_00026970;
      }
    }
    else if (param_2 + uVar5 == 0) {
      cVar1 = FUN_00038260();
      if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
        pcVar7 = "No proper DtTable\n";
        goto LAB_00026970;
      }
    }
    else {
      uVar3 = FUN_0003832c(*(undefined4 *)(param_2 + 0x10));
      if (uVar3 != 0) {
        uVar8 = 0;
        puVar9 = (undefined4 *)(param_2 + uVar5 + 4);
        do {
          uVar5 = FUN_0003832c(*puVar9);
          if (~(uVar5 & 0xffffffff) < param_2) {
            cVar1 = FUN_00038260();
            if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0'))
            goto LAB_00026978;
            pcVar7 = "Integer overflow detected with Dtbo address\n";
            goto LAB_00026970;
          }
          uVar5 = FUN_0003832c(*puVar9);
          lVar6 = param_2 + (uVar5 & 0xffffffff);
          iVar4 = FUN_00036c38(lVar6);
          if ((iVar4 != 0) || (iVar4 = FUN_00027788(lVar6), iVar4 != 0)) {
            cVar1 = FUN_00038260();
            if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
              FUN_00037d9c(0x80000000,"No Valid Dtb\n");
            }
            break;
          }
          local_50 = lVar6;
          cVar1 = FUN_00025700(&local_90,&local_e0,0x1c);
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"Dtbo count = %u LocalBoardDtMatch = %x\n",uVar8,uStack_58._4_4_);
          }
          if (cVar1 != '\0') {
            DAT_0023fe24 = uVar8;
          }
          uVar8 = uVar8 + 1;
          puVar9 = puVar9 + 8;
        } while (uVar8 < uVar3);
      }
      lVar6 = local_a0;
      if (local_a0 != 0) goto LAB_0002697c;
      cVar1 = FUN_00038260();
      if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
        pcVar7 = "Unable to find the Board Dtb\n";
        goto LAB_00026970;
      }
    }
  }
LAB_00026978:
  lVar6 = 0;
LAB_0002697c:
  if (DAT_0023fe10 != local_48) {
                    /* WARNING: Subroutine does not return */
    FUN_0001e34c(lVar6);
  }
  return;
}

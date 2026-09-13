longlong FUN_000263c8(ulonglong *param_1)
{
  char cVar1;
  uint uVar2;
  int iVar3;
  longlong lVar4;
  ulonglong uVar5;
  char *pcVar6;
  ulonglong uVar7;
  int local_c4;
  undefined8 local_c0 [2];
  undefined8 local_b0;
  undefined8 *puStack_a8;
  int local_9c;
  undefined1 auStack_98 [8];
  longlong local_90;
  undefined8 local_80;
  undefined8 uStack_78;
  undefined8 uStack_70;
  undefined8 uStack_68;
  undefined8 local_60;
  undefined8 uStack_58;
  undefined8 uStack_50;
  undefined8 uStack_48;
  undefined8 local_40;
  longlong local_38;
  
  local_38 = DAT_0023fe10;
  local_9c = 0;
  local_40 = 0;
  uStack_58 = 0;
  local_60 = 0;
  uStack_48 = 0;
  uStack_50 = 0;
  uStack_78 = 0;
  local_80 = 0;
  uStack_68 = 0;
  uStack_70 = 0;
  local_c4 = 1;
  lVar4 = FUN_000399b4(L"user_dtbo");
  if (0x14 < lVar4 * 2 + 2U) {
    FUN_0003a9c4("StrLen",800);
  }
  if (0x14 < (ulonglong)(lVar4 * 2)) {
    FUN_0003a9c4("StrnCpyS",0x14a);
  }
  lVar4 = FUN_00038b20(&local_80,0x24,L"user_dtbo",lVar4);
  if (lVar4 != 0) {
    cVar1 = FUN_00038260();
    if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
      FUN_00037d9c(0x80000000,"Err: line:%d %a() status: %r\n",0x414,"GetOvrdDtb",lVar4);
    }
    goto LAB_00026568;
  }
  local_c0[0] = 0;
  local_b0 = 0;
  puStack_a8 = &local_80;
  lVar4 = FUN_00029a30(0x20e,local_c0,auStack_98,&local_c4);
  if ((lVar4 == 0) && (local_c4 == 1)) {
    local_9c = (*(int *)(*(longlong *)(local_90 + 8) + 0x18) + 1) *
               *(int *)(*(longlong *)(local_90 + 8) + 0xc);
    uVar5 = FUN_0000ee70();
    *param_1 = uVar5;
    if (uVar5 == 0) {
      cVar1 = FUN_00038260();
      lVar4 = -0x7ffffffffffffff7;
      if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0')) goto LAB_0002655c;
      FUN_00037d9c(0x80000000,"Override DTB: Buffer allocation failure\n");
      lVar4 = -0x7ffffffffffffff7;
      uVar5 = *param_1;
    }
    else {
      lVar4 = FUN_00029eb8(uVar5,&local_9c,&local_80);
      if (lVar4 != 0) {
        cVar1 = FUN_00038260();
        if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
          FUN_00037d9c(0x80000000,"Override DTB: DtboImgBuffer loading falied\n");
        }
        goto LAB_00026568;
      }
      uVar7 = *param_1;
      uVar5 = FUN_0003832c(*(undefined4 *)(uVar7 + 0x14));
      if (~(uVar5 & 0xffffffff) < *param_1) {
        lVar4 = -0x7ffffffffffffffe;
        cVar1 = FUN_00038260();
        if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0')) goto LAB_0002655c;
        pcVar6 = "Override DTB: Integer overflow detected Dtbo address\n";
      }
      else {
        lVar4 = *param_1 + (uVar5 & 0xffffffff);
        if (lVar4 == 0) {
          lVar4 = -0x7ffffffffffffffe;
          cVar1 = FUN_00038260();
          if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0'))
          goto LAB_0002655c;
          pcVar6 = "Override DTB: No proper DtTable\n";
        }
        else {
          uVar2 = FUN_0003832c(*(undefined4 *)(uVar7 + 0x10));
          if (uVar2 < 2) {
            uVar5 = *param_1;
            uVar7 = FUN_0003832c(*(undefined4 *)(lVar4 + 4));
            uVar5 = uVar5 + (uVar7 & 0xffffffff);
            iVar3 = FUN_00036c38(uVar5);
            if ((iVar3 == 0) && (iVar3 = FUN_00027788(uVar5), iVar3 == 0)) {
              lVar4 = 0;
              *param_1 = uVar5;
              goto LAB_00026568;
            }
            lVar4 = -0x7ffffffffffffffe;
            cVar1 = FUN_00038260();
            if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0'))
            goto LAB_0002655c;
            pcVar6 = "Override DTB: No Valid DTB in image\n";
          }
          else {
            lVar4 = -0x7ffffffffffffffe;
            cVar1 = FUN_00038260();
            if ((cVar1 == '\0') || (cVar1 = FUN_0003828c(0x80000000), cVar1 == '\0'))
            goto LAB_0002655c;
            pcVar6 = "Override DTB: Exceeding maximum supported dtb count in Image\n";
          }
        }
      }
      lVar4 = -0x7ffffffffffffffe;
      FUN_00037d9c(0x80000000,pcVar6);
      uVar5 = *param_1;
    }
  }
  else {
    cVar1 = FUN_00038260();
    if ((cVar1 != '\0') && (cVar1 = FUN_0003828c(0x80000000), cVar1 != '\0')) {
      FUN_00037d9c(0x80000000,"Override DTB: GetBlkIOHandles failed loading user_dtbo!\n");
    }
    lVar4 = -0x7fffffffffffffff;
LAB_0002655c:
    uVar5 = *param_1;
  }
  if (uVar5 != 0) {
    FUN_0000f00c();
  }
LAB_00026568:
  if (DAT_0023fe10 != local_38) {
                    /* WARNING: Subroutine does not return */
    FUN_0001e34c();
  }
  return lVar4;
}

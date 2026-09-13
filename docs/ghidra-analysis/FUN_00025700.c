void FUN_00025700(short *param_1,longlong param_2,uint param_3)
{
  byte bVar1;
  char cVar2;
  undefined2 uVar3;
  short sVar4;
  int iVar5;
  undefined4 uVar6;
  int iVar7;
  uint uVar8;
  int iVar9;
  uint uVar10;
  uint uVar11;
  uint extraout_var;
  undefined4 *puVar12;
  longlong lVar13;
  char *pcVar14;
  longlong lVar15;
  ulonglong uVar16;
  ulonglong uVar17;
  undefined8 uVar18;
  uint *puVar19;
  ulonglong uVar20;
  uint local_cc;
  uint local_c8;
  uint local_c4;
  undefined1 local_c0 [16];
  uint local_b0;
  uint uStack_ac;
  uint uStack_a8;
  uint uStack_a4;
  uint local_a0;
  uint local_90 [4];
  uint local_80 [4];
  uint local_70;
  longlong local_68;
  
  local_68 = DAT_0023fe10;
  uVar18 = *(undefined8 *)(param_1 + 0x20);
  FUN_0000f348(local_c0,0x24,0);
  puVar19 = (uint *)(param_1 + 0x1e);
  *puVar19 = 0;
  iVar5 = FUN_000356e8(uVar18,&DAT_000b15c7);
  if (iVar5 < 0) {
    cVar2 = FUN_00038260();
    if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x80000000), cVar2 != '\0')) {
      FUN_00037d9c(0x80000000,"Unable to locate root node\n");
    }
  }
  else {
    puVar12 = (undefined4 *)FUN_00035bd8(uVar18,iVar5,"qcom,msm-id",&local_c8);
    if (((puVar12 == (undefined4 *)0x0) || ((int)local_c8 < 1)) || ((local_c8 & 7) != 0)) {
      cVar2 = FUN_00038260();
      if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
        FUN_00037d9c(0x400000,"qcom, msm-id does not exist (or) is (%d) not a multiple of (%d)\n",
                     local_c8,8);
      }
LAB_00025a1c:
      puVar12 = (undefined4 *)FUN_00035bd8(uVar18,iVar5,"qcom,board-id",&local_c4);
      if (((puVar12 == (undefined4 *)0x0) || ((int)local_c4 < 1)) || ((local_c4 & 7) != 0)) {
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          FUN_00037d9c(0x400000,"qcom,board-id does not exist (or) (%d) is not a multiple of (%d)\n"
                       ,local_c4,8);
        }
      }
      else {
        uVar6 = FUN_0003832c(*puVar12);
        *(undefined4 *)(param_1 + 6) = uVar6;
        iVar9 = FUN_0003832c(puVar12[1]);
        *(int *)(param_1 + 0xc) = iVar9;
        if (iVar9 == 0) {
          FUN_0003832c(*puVar12);
          *(uint *)(param_1 + 0xc) = extraout_var & 0xff;
        }
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          uVar6 = FUN_00020118();
          FUN_00037d9c(0x400000,"BoardVariant = %x, DtVariant = %x\n",uVar6,
                       *(undefined4 *)(param_1 + 6));
        }
        uVar8 = *(uint *)(param_1 + 6);
        uVar20 = CONCAT44(uVar8,uVar8) & 0xff0000000000ff;
        iVar7 = (int)uVar20;
        *(int *)(param_1 + 6) = iVar7;
        *(int *)(param_1 + 8) = (int)(uVar20 >> 0x20);
        *(uint *)(param_1 + 10) = uVar8 & 0xff00;
        iVar9 = FUN_00020118();
        if (iVar7 != iVar9) {
          if (*(int *)(param_1 + 6) == 0) goto LAB_00025b68;
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            pcVar14 = "qcom,board-id does not match\n";
LAB_000260c0:
            FUN_00037d9c(0x400000,pcVar14);
          }
LAB_000260c8:
          *puVar19 = 1;
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            pcVar14 = "Board dt prop search failed.\n";
            goto LAB_000260f4;
          }
          goto LAB_000260fc;
        }
        *puVar19 = *puVar19 | 0x10000000;
LAB_00025b68:
        uVar8 = *(uint *)(param_1 + 8);
        uVar11 = FUN_000201a0();
        if (uVar8 == (uVar11 & 0xff0000)) {
          *puVar19 = *puVar19 | 0x1000;
        }
        else {
          uVar8 = *(uint *)(param_1 + 8);
          uVar11 = FUN_000201a0();
          if (uVar8 < (uVar11 & 0xff0000)) {
            *puVar19 = *puVar19 | 0x800;
          }
          else if (((*(int *)(param_1 + 8) != 0) && (cVar2 = FUN_00038260(), cVar2 != '\0')) &&
                  (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"qcom,board-id major version does not match\n");
          }
        }
        uVar8 = *(uint *)(param_1 + 10);
        uVar11 = FUN_000201a0();
        if (uVar8 == (uVar11 & 0xff00)) {
          *puVar19 = *puVar19 | 0x400;
        }
        else {
          uVar8 = *(uint *)(param_1 + 10);
          uVar11 = FUN_000201a0();
          if (uVar8 < (uVar11 & 0xff00)) {
            *puVar19 = *puVar19 | 0x200;
          }
          else if (((*(int *)(param_1 + 10) != 0) && (cVar2 = FUN_00038260(), cVar2 != '\0')) &&
                  (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"qcom,board-id minor version does not match\n");
          }
        }
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          uVar6 = FUN_00020158();
          FUN_00037d9c(0x400000,"BoardSubtype = %x, DtSubType = %x\n",uVar6,
                       *(undefined4 *)(param_1 + 0xc));
        }
        bVar1 = *(byte *)(param_1 + 0xc);
        uVar8 = FUN_00013de8();
        if (bVar1 == uVar8) {
          uVar8 = 0x4000000;
        }
        else {
          bVar1 = *(byte *)(param_1 + 0xc);
          uVar8 = FUN_00013de8();
          if (uVar8 <= bVar1) {
            cVar2 = FUN_00038260();
            if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
              pcVar14 = "subtype-id doesnot match\n";
              goto LAB_000260c0;
            }
            goto LAB_000260c8;
          }
          uVar8 = 0x2000000;
        }
        uVar11 = *(uint *)(param_1 + 0xc);
        *(uint *)(param_1 + 0x1e) = *(uint *)(param_1 + 0x1e) | uVar8;
        uVar8 = FUN_00020320();
        if (((uVar8 ^ uVar11) & 0x700) == 0) {
          *puVar19 = *puVar19 | 0x8000000;
        }
        else {
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"ddr size does not match\n");
          }
        }
      }
      lVar13 = FUN_00035bd8(uVar18,iVar5,"qcom,pmic-id",&local_cc);
      if (((lVar13 == 0) || ((int)local_cc < 1)) || ((local_cc & 0xf) != 0)) {
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          FUN_00037d9c(0x400000,"qcom,pmic-id does not exit (or) is (%d) not a multiple of (%d)\n",
                       local_cc,0x10);
        }
      }
      else {
        FUN_0000f348(local_c0,0x24,0);
        if (local_cc >> 4 != 0) {
          uVar8 = 0;
          do {
            FUN_0000f348(local_90,0x24,0);
            uVar20 = 0;
            uVar17 = 1;
            do {
              uVar11 = FUN_0003832c(*(undefined4 *)(lVar13 + uVar20 * 4));
              local_90[uVar20] = uVar11;
              cVar2 = FUN_00038260();
              if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
                FUN_00037d9c(0x400000,"pmic_data[%u].:%x\n",uVar20 & 0xffffffff,local_90[uVar20]);
              }
              uVar10 = local_90[uVar20];
              uVar11 = uVar10 & 0xff;
              local_80[uVar20] = uVar10 & 0xffffff00;
              local_90[uVar20] = uVar11;
              uVar10 = FUN_0001f1c0(uVar20 & 0xffffffff);
              if (uVar11 != uVar10) {
                if (local_90[uVar20] == 0) {
                  lVar15 = 0x11;
                  goto LAB_00025e2c;
                }
                local_70 = 1;
                cVar2 = FUN_00038260();
                if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
                  pcVar14 = "Pmic model does not match\n";
LAB_00025f00:
                  FUN_00037d9c(0x400000,pcVar14);
                }
                break;
              }
              lVar15 = 0x12;
LAB_00025e2c:
              local_70 = local_70 | (uint)(1L << ((uVar17 + lVar15) - 1 & 0x3f));
              uVar11 = local_80[uVar20];
              uVar10 = FUN_0001f3a8(uVar20 & 0xffffffff);
              if (uVar11 == (uVar10 & 0xffffff00)) {
                uVar16 = uVar20 * 2 + 2;
              }
              else {
                uVar11 = local_80[uVar20];
                uVar10 = FUN_0001f3a8(uVar20 & 0xffffffff);
                uVar16 = uVar17;
                if ((uVar10 & 0xffffff00) <= uVar11) {
                  cVar2 = FUN_00038260();
                  if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
                    pcVar14 = "Pmic revision does not match\n";
                    goto LAB_00025f00;
                  }
                  break;
                }
              }
              uVar20 = uVar20 + 1;
              uVar17 = uVar17 + 2;
              local_70 = local_70 | (uint)(1L << (uVar16 & 0x3f));
            } while (uVar20 < 4);
            cVar2 = FUN_00038260();
            if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
              FUN_00037d9c(0x400000,
                           "BestPmicInfo.DtMatchVal : %x CurPmicInfo[%u]->DtMatchVal : %x\n",
                           local_a0,uVar8,local_70);
            }
            if ((local_a0 < local_70) ||
               ((local_a0 == local_70 &&
                ((((local_b0 < local_80[0] || (uStack_ac < local_80[1])) ||
                  (uStack_a8 < local_80[2])) || (uStack_a4 < local_80[3])))))) {
              (**(code **)(DAT_00260138 + 0x160))(local_c0,local_90,0x24);
            }
            lVar13 = lVar13 + 0x10;
            uVar8 = uVar8 + 1;
          } while (uVar8 != local_cc >> 4);
        }
        *(uint *)(param_1 + 0x16) = local_b0;
        *(int *)(param_1 + 0xe) = (int)local_c0._0_8_;
        *(uint *)(param_1 + 0x1e) = *(uint *)(param_1 + 0x1e) | local_a0;
        *(int *)(param_1 + 0x10) = SUB84(local_c0._0_8_,4);
        *(int *)(param_1 + 0x12) = (int)local_c0._8_8_;
        *(int *)(param_1 + 0x14) = SUB84(local_c0._8_8_,4);
        *(uint *)(param_1 + 0x18) = uStack_ac;
        *(uint *)(param_1 + 0x1a) = uStack_a8;
        *(uint *)(param_1 + 0x1c) = uStack_a4;
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          FUN_00037d9c(0x400000,"CurDtbInfo->DtMatchVal : %x  BestPmicInfo.DtMatchVal :%x\n",
                       *puVar19,local_a0);
        }
      }
    }
    else {
      uVar6 = FUN_0003832c(*puVar12);
      *(undefined4 *)param_1 = uVar6;
      cVar2 = FUN_00038260();
      if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
        uVar3 = FUN_0001fee0();
        FUN_00037d9c(0x400000,"Boardsocid = %x, Dtsocid = %x\n",uVar3,*param_1);
      }
      sVar4 = FUN_0001fee0();
      if (*param_1 == sVar4) {
        *(uint *)(param_1 + 0x1e) = *(uint *)(param_1 + 0x1e) | 0x20000000;
        uVar6 = FUN_0003832c(puVar12[1]);
        *(undefined4 *)(param_1 + 2) = uVar6;
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          uVar6 = FUN_0001ff28();
          FUN_00037d9c(0x400000,"BoardSocRev = %x, DtSocRev =%x\n",uVar6,
                       *(undefined4 *)(param_1 + 2));
        }
        iVar9 = *(int *)(param_1 + 2);
        iVar7 = FUN_0001ff28();
        if (iVar9 == iVar7) {
          *puVar19 = *puVar19 | 0x4000;
        }
        else {
          uVar8 = *(uint *)(param_1 + 2);
          uVar11 = FUN_0001ff28();
          if (uVar8 < uVar11) {
            *puVar19 = *puVar19 | 0x2000;
          }
          else if (((*(int *)(param_1 + 2) != 0) && (cVar2 = FUN_00038260(), cVar2 != '\0')) &&
                  (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
            FUN_00037d9c(0x400000,"soc version does not match\n");
          }
        }
        uVar8 = FUN_0003832c(*puVar12);
        *(uint *)(param_1 + 4) = uVar8 & 0xff0000;
        cVar2 = FUN_00038260();
        if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
          iVar9 = FUN_0001ff70();
          FUN_00037d9c(0x400000,"BoardFoundry = %x, DtFoundry = %x\n",iVar9 << 0x10,
                       *(undefined4 *)(param_1 + 4));
        }
        iVar9 = *(int *)(param_1 + 4);
        iVar7 = FUN_0001ff70();
        if (iVar9 == iVar7 * 0x10000) {
          uVar8 = *puVar19 | 0x10000;
        }
        else {
          if (*(int *)(param_1 + 4) != 0) {
            cVar2 = FUN_00038260();
            if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
              pcVar14 = "soc foundry does not match\n";
              goto LAB_00025818;
            }
            goto LAB_00025820;
          }
          uVar8 = *puVar19 | 0x8000;
        }
        *puVar19 = uVar8;
        goto LAB_00025a1c;
      }
      cVar2 = FUN_00038260();
      if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
        pcVar14 = "qcom,msm-id does not match\n";
LAB_00025818:
        FUN_00037d9c(0x400000,pcVar14);
      }
LAB_00025820:
      *puVar19 = 1;
      cVar2 = FUN_00038260();
      if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x400000), cVar2 != '\0')) {
        pcVar14 = "Platform dt prop search failed.\n";
LAB_000260f4:
        FUN_00037d9c(0x400000,pcVar14);
      }
    }
LAB_000260fc:
    uVar8 = *puVar19;
    if ((1L << ((ulonglong)param_3 & 0x3f) & (ulonglong)uVar8) != 0) {
      if (*(uint *)(param_2 + 0x3c) < uVar8) goto LAB_00026120;
      if (*(uint *)(param_2 + 0x3c) != uVar8) goto LAB_000261c8;
      if (((*(uint *)(param_2 + 4) < *(uint *)(param_1 + 2)) ||
          (*(uint *)(param_2 + 0x10) < *(uint *)(param_1 + 8))) ||
         (*(uint *)(param_2 + 0x14) < *(uint *)(param_1 + 10))) {
LAB_00026120:
        (**(code **)(DAT_00260138 + 0x160))(param_2,param_1,0x48);
      }
      else {
        uVar8 = *(uint *)(param_1 + 0xc);
        uVar11 = FUN_00013de8();
        if (uVar11 < uVar8) {
          if (((*(uint *)(param_1 + 0x16) <= *(uint *)(param_2 + 0x2c)) &&
              (*(uint *)(param_1 + 0x18) <= *(uint *)(param_2 + 0x30))) &&
             ((*(uint *)(param_1 + 0x1a) <= *(uint *)(param_2 + 0x34) &&
              (*(uint *)(param_1 + 0x1c) <= *(uint *)(param_2 + 0x38))))) goto LAB_000261c8;
          goto LAB_00026120;
        }
        if (*(uint *)(param_2 + 0x18) < *(uint *)(param_1 + 0xc)) {
          cVar2 = FUN_00038260();
          if ((cVar2 != '\0') && (cVar2 = FUN_0003828c(0x80000000), cVar2 != '\0')) {
            uVar6 = FUN_00013de8();
            FUN_00037d9c(0x80000000,"FindBestMatch GetBoardRev = %x, DtSubType = %x\n",uVar6,
                         *(undefined4 *)(param_1 + 0xc));
          }
          goto LAB_00026120;
        }
      }
      uVar18 = 1;
      goto LAB_000261cc;
    }
  }
LAB_000261c8:
  uVar18 = 0;
LAB_000261cc:
  if (DAT_0023fe10 != local_68) {
                    /* WARNING: Subroutine does not return */
    FUN_0001e34c(uVar18);
  }
  return;
}

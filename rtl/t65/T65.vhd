-- ****
-- T65(b) core. In an effort to merge and maintain bug fixes ....
--
-- Ver 313 WoS January 2015
--   Fixed issue that NMI has to be first if issued the same time as a BRK instruction is latched in
--   Now all Lorenz CPU tests on FPGAARCADE C64 core (sources used: SVN version 1021) are OK! :D :D :D
--   This is just a starting point to go for optimizations and detailed fixes (the Lorenz test can't find)
--
-- Ver 312 WoS January 2015
--   Undoc opcode timing fixes for $B3 (LAX iy) and $BB (LAS ay)
--   Added comments in MCode section to find handling of individual opcodes more easily
--   All "basic" Lorenz instruction test (individual functional checks, CPUTIMING check) work now with 
--       actual FPGAARCADE C64 core (sources used: SVN version 1021).
--
-- Ver 305, 306, 307, 308, 309, 310, 311 WoS January 2015
--   Undoc opcode fixes (now all Lorenz test on instruction functionality working, except timing issues on $B3 and $BB):
--     SAX opcode
--     SHA opcode
--     SHX opcode
--     SHY opcode
--     SHS opcode
--     LAS opcode
--     alternate SBC opcode
--     fixed NOP with immediate param (caused Lorenz trap test to fail)
--     IRQ and NMI timing fixes (in conjuction with branches)
--
-- Ver 304 WoS December 2014
--   Undoc opcode fixes:
--     ARR opcode
--     ANE/XAA opcode
--   Corrected issue with NMI/IRQ prio (when asserted the same time)
--
-- Ver 303 ost(ML) July 2014
--   (Sorry for some scratchpad comments that may make little sense)
--   Mods and some 6502 undocumented instructions.
--   Not correct opcodes acc. to Lorenz tests (incomplete list):
--     NOPN    (nop)
--     NOPZX   (nop + byte 172)
--     NOPAX   (nop + word da  ...  da:  byte 0)
--     ASOZ    (byte $07 + byte 172)
--
-- Ver 303,302 WoS April 2014
--     Bugfixes for NMI from foft
--     Bugfix for BRK command (and its special flag)
--
-- Ver 300,301 WoS January 2014
--     More merging
--     Bugfixes by ehenciak added, started tidyup *bust*
--
-- MikeJ March 2005
--      Latest version from www.fpgaarcade.com (original www.opencores.org)
-- ****
--
-- 65xx compatible microprocessor core
--
-- FPGAARCADE SVN: $Id: T65.vhd 1347 2015-05-27 20:07:34Z wolfgang.scherr $
--
-- Copyright (c) 2002...2015
--               Daniel Wallner (jesus <at> opencores <dot> org)
--               Mike Johnson   (mikej <at> fpgaarcade <dot> com)
--               Wolfgang Scherr (WoS <at> pin4 <dot> at>
--               Morten Leikvoll ()
--
-- All rights reserved
--
-- Redistribution and use in source and synthezised forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- Redistributions in synthesized form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- Neither the name of the author nor the names of other contributors may
-- be used to endorse or promote products derived from this software without
-- specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
--
-- Please report bugs to the author(s), but before you do so, please
-- make sure that this is not a derivative work and that
-- you have the latest version of this file.
--
-- ----- IMPORTANT NOTES -----
--
-- Limitations:
--   65C02 and 65C816 modes are incomplete (and definitely untested after all 6502 undoc fixes)
--      65C02 supported : inc, dec, phx, plx, phy, ply
--      65D02 missing : bra, ora, lda, cmp, sbc, tsb*2, trb*2, stz*2, bit*2, wai, stp, jmp, bbr*8, bbs*8
--   Some interface signals behave incorrect
--   NMI interrupt handling not nice, needs further rework (to cycle-based encoding).
--
-- Usage:
--   The enable signal allows clock gating / throttling without using the ready signal.
--   Set it to constant '1' when using the Clk input as the CPU clock directly.
--
--   TAKE CARE you route the DO signal back to the DI signal while R_W_n='0',
--   otherwise some undocumented opcodes won't work correctly.
--   EXAMPLE:
--      CPU : entity work.T65
--          port map (
--              R_W_n   => cpu_rwn_s,
--              [....all other ports....]
--              DI      => cpu_din_s,
--              DO      => cpu_dout_s
--          );
--      cpu_din_s <= cpu_dout_s when cpu_rwn_s='0' else 
--                   [....other sources from peripherals and memories...]
--
-- ----- IMPORTANT NOTES -----
--

library IEEE;
  use IEEE.std_logic_1164.all;
  use IEEE.numeric_std.all;
  use work.T65_Pack.all;

entity T65 is
  port(
    Mode    : in  std_logic_vector(1 downto 0);      -- "00" => 6502, "01" => 65C02, "10" => 65C816
    Res_n   : in  std_logic;
    Enable  : in  std_logic;
    Clk     : in  std_logic;
    Rdy     : in  std_logic;
    Abort_n : in  std_logic;
    IRQ_n   : in  std_logic;
    NMI_n   : in  std_logic;
    SO_n    : in  std_logic;
    R_W_n   : out std_logic;
    Sync    : out std_logic;
    EF      : out std_logic;
    MF      : out std_logic;
    XF      : out std_logic;
    ML_n    : out std_logic;
    VP_n    : out std_logic;
    VDA     : out std_logic;
    VPA     : out std_logic;
    A       : out std_logic_vector(23 downto 0);
    DI      : in  std_logic_vector(7 downto 0);
    DO      : out std_logic_vector(7 downto 0);
    DEBUG   : out T_t65_dbg
  );
end T65;

architecture rtl of T65 is

  -- Registers
  signal ABC, X, Y, D       : std_logic_vector(15 downto 0);
  signal P, AD, DL          : std_logic_vector(7 downto 0) :=  x"00";
  signal PwithB             : std_logic_vector(7 downto 0);--ML:New way to push P with correct B state to stack
  signal BAH                : std_logic_vector(7 downto 0);
  signal BAL                : std_logic_vector(8 downto 0);
  signal PBR                : std_logic_vector(7 downto 0);
  signal DBR                : std_logic_vector(7 downto 0);
  signal PC                 : unsigned(15 downto 0);
  signal S                  : unsigned(15 downto 0);
  signal EF_i               : std_logic;
  signal MF_i               : std_logic;
  signal XF_i               : std_logic;

  signal IR                 : std_logic_vector(7 downto 0);
  signal MCycle             : std_logic_vector(2 downto 0);

  signal Mode_r             : std_logic_vector(1 downto 0);
  signal ALU_Op_r           : T_ALU_Op;
  signal Write_Data_r       : T_Write_Data;
  signal Set_Addr_To_r      : T_Set_Addr_To;
  signal PCAdder            : unsigned(8 downto 0);

  signal RstCycle           : std_logic;
  signal IRQCycle           : std_logic;
  signal NMICycle           : std_logic;

  signal SO_n_o             : std_logic;
  signal IRQ_n_o            : std_logic;
  signal NMI_n_o            : std_logic;
  signal NMIAct             : std_logic;

  signal Break              : std_logic;

  -- ALU signals
  signal BusA               : std_logic_vector(7 downto 0);
  signal BusA_r             : std_logic_vector(7 downto 0);
  signal BusB               : std_logic_vector(7 downto 0);
  signal BusB_r             : std_logic_vector(7 downto 0);
  signal ALU_Q              : std_logic_vector(7 downto 0);
  signal P_Out              : std_logic_vector(7 downto 0);

  -- Micro code outputs
  signal LCycle             : std_logic_vector(2 downto 0);
  signal ALU_Op             : T_ALU_Op;
  signal Set_BusA_To        : T_Set_BusA_To;
  signal Set_Addr_To        : T_Set_Addr_To;
  signal Write_Data         : T_Write_Data;
  signal Jump               : std_logic_vector(1 downto 0);
  -- LOCAL PATCH (see patches/ and ERRATA E-10): the taken-branch page-cross
  -- fixup is deferred one cycle so that PC+2 is visible on the bus, as on
  -- the die.  "00" none, "01" carry (PCH+1), "10" borrow (PCH-1).
  signal PCHFix             : std_logic_vector(1 downto 0);
  -- LOCAL PATCH (see patches/ and ERRATA E-11): JAM/KIL really stops the CPU.
  signal Jam                : std_logic;
  signal JamPhase           : unsigned(1 downto 0);
  signal IsJam              : std_logic;
  signal A_i                : std_logic_vector(23 downto 0);
  -- LOCAL PATCH (ERRATA E-52): an indexed SHA/SHX/SHY/TAS crossed a page
  signal SHCross            : std_logic;
  signal BAH_eff            : std_logic_vector(7 downto 0);
  signal sh_step_held       : std_logic;  -- E-54: this step has been held by RDY
  signal sh_drop            : std_logic;  -- E-54: the step just completed was held
  signal sh_mask            : std_logic_vector(7 downto 0);
  signal sh_addr            : std_logic_vector(7 downto 0);
  signal BAAdd              : std_logic_vector(1 downto 0);
  signal BreakAtNA          : std_logic;
  signal ADAdd              : std_logic;
  signal AddY               : std_logic;
  signal PCAdd              : std_logic;
  signal Inc_S              : std_logic;
  signal Dec_S              : std_logic;
  signal LDA                : std_logic;
  signal LDP                : std_logic;
  signal LDX                : std_logic;
  signal LDY                : std_logic;
  signal LDS                : std_logic;
  signal LDDI               : std_logic;
  signal LDALU              : std_logic;
  signal LDAD               : std_logic;
  signal LDBAL              : std_logic;
  signal LDBAH              : std_logic;
  signal SaveP              : std_logic;
  signal Write              : std_logic;

  signal Res_n_i        : std_logic;
  signal Res_n_d        : std_logic;

  signal really_rdy     : std_logic;
  -- LOCAL PATCH (ERRATA E-41): RDY held ANE's operand cycle
  signal ane_held       : std_logic;
  -- LOCAL PATCH (ERRATA E-39): T0 held by RDY, the polls made while it was
  -- held, and the I flag the die polls with
  signal t0_held        : std_logic;
  signal irq_req        : std_logic;
  signal nmi_req        : std_logic;
  signal I_eff          : std_logic;
  signal irq_raw_o      : std_logic;  -- /IRQ latched every Enable, branch or not
  -- LOCAL PATCH (ERRATA E-39): a branch's IRQ poll, made at its operand cycle
  signal br_irq         : std_logic;
  signal br_first       : std_logic;
  signal ane_magic      : std_logic_vector(7 downto 0);
  signal WRn_i          : std_logic;

  signal NMI_entered    : std_logic;

begin
  -- gate Rdy with read/write to make an "OK, it's really OK to stop the processor 
  really_rdy <= Rdy or not(WRn_i);
  ane_magic <= x"ee" when ane_held = '1' else x"ef";
  -- CLI/SEI have written I by the first held repeat of their T0 (ERRATA E-39)
  I_eff <= '0' when IR = x"58" else '1' when IR = x"78" else P(Flag_I);
  Sync <= '1' when MCycle = "000" else '0';
  -- LOCAL PATCH (ERRATA E-11).  The twelve JAMs are $x2 for every high nibble
  -- except 8, A, C and E -- $82/$C2/$E2 are undocumented NOP #imm and $A2 is
  -- LDX #imm -- which is precisely "low nibble 2, and not (bit7 and not bit4)".
  IsJam <= '1' when IR(3 downto 0) = "0010" and (IR(7) = '0' or IR(4) = '1')
           else '0';
  EF <= EF_i;
  MF <= MF_i;
  XF <= XF_i;
  R_W_n <= WRn_i;
  ML_n <= '0' when IR(7 downto 6) /= "10" and IR(2 downto 1) = "11" and MCycle(2 downto 1) /= "00" else '1';
  VP_n <= '0' when IRQCycle = '1' and (MCycle = "101" or MCycle = "110") else '1';
  VDA <= '1' when Set_Addr_To_r /= Set_Addr_To_PBR else '0';
  VPA <= '1' when Jump(1) = '0' else '0';

  -- debugging signals
  DEBUG.I <= IR;
  DEBUG.A <= ABC(7 downto 0);
  DEBUG.X <= X(7 downto 0);
  DEBUG.Y <= Y(7 downto 0);
  DEBUG.S <= std_logic_vector(S(7 downto 0));
  DEBUG.P <= P;

  mcode : entity work.T65_MCode
    port map(
--inputs
      Mode        => Mode_r,
      IR          => IR,
      MCycle      => MCycle,
      P           => P,
--outputs
      LCycle      => LCycle,
      ALU_Op      => ALU_Op,
      Set_BusA_To => Set_BusA_To,
      Set_Addr_To => Set_Addr_To,
      Write_Data  => Write_Data,
      Jump        => Jump,
      BAAdd       => BAAdd,
      BreakAtNA   => BreakAtNA,
      ADAdd       => ADAdd,
      AddY        => AddY,
      PCAdd       => PCAdd,
      Inc_S       => Inc_S,
      Dec_S       => Dec_S,
      LDA         => LDA,
      LDP         => LDP,
      LDX         => LDX,
      LDY         => LDY,
      LDS         => LDS,
      LDDI        => LDDI,
      LDALU       => LDALU,
      LDAD        => LDAD,
      LDBAL       => LDBAL,
      LDBAH       => LDBAH,
      SaveP       => SaveP,
      Write       => Write
      );

  alu : entity work.T65_ALU
    port map(
      Mode => Mode_r,
      Op => ALU_Op_r,
      BusA => BusA_r,
      BusB => BusB,
      P_In => P,
      P_Out => P_Out,
      Q => ALU_Q
      );

  -- the 65xx design requires at least two clock cycles before
  -- starting its reset sequence (according to datasheet)
  process (Res_n_i, Clk)
  begin
    if Res_n = '0' then
      Res_n_i <= '0';
      Res_n_d <= '0';
    elsif Clk'event and Clk = '1' then
      Res_n_i <= Res_n_d;
      Res_n_d <= '1';
    end if;
  end process;

  process (Res_n_i, Clk)
  begin
    if Res_n_i = '0' then
      PC <= (others => '0');  -- Program Counter
      IR <= "00000000";
      S <= (others => '0');       -- Dummy
      D <= (others => '0');
      PBR <= (others => '0');
      DBR <= (others => '0');

      Mode_r <= (others => '0');
      ALU_Op_r <= ALU_OP_BIT;
      Write_Data_r <= Write_Data_DL;
      PCHFix <= "00";
      Set_Addr_To_r <= Set_Addr_To_PBR;

      WRn_i <= '1';
      EF_i <= '1';
      MF_i <= '1';
      XF_i <= '1';

    elsif Clk'event and Clk = '1' then  
      if (Enable = '1') then
        if (really_rdy = '1') then
          WRn_i <= not Write or RstCycle;

          D <= (others => '1');   -- Dummy
          PBR <= (others => '1'); -- Dummy
          DBR <= (others => '1'); -- Dummy
          EF_i <= '0';    -- Dummy
          MF_i <= '0';    -- Dummy
          XF_i <= '0';    -- Dummy

          if MCycle  = "000" then
            Mode_r <= Mode;

            if IRQCycle = '0' and NMICycle = '0' then
              PC <= PC + 1;
            end if;

            if IRQCycle = '1' or NMICycle = '1' then
              IR <= "00000000";
            else
              IR <= DI;
            end if;

            if LDS = '1' then -- LAS won't work properly if not limited to machine cycle 0
              S(7 downto 0) <= unsigned(ALU_Q);
            end if;
          end if;

          ALU_Op_r <= ALU_Op;
          Write_Data_r <= Write_Data;
          if Break = '1' then
            Set_Addr_To_r <= Set_Addr_To_PBR;
          else
            Set_Addr_To_r <= Set_Addr_To;
          end if;

          if Inc_S = '1' then
            S <= S + 1;
          end if;
          -- LOCAL PATCH (ERRATA E-51): the NMOS die runs its reset through the
          -- BRK sequence with the writes turned into reads, so S steps down by
          -- three (perfect6502: reads at $01C0, $01BF, $01BE, then PHP pushes
          -- at $01BD).  Upstream held S during reset.
          if Dec_S = '1' then
            S <= S - 1;
          end if;

          if IR = "00000000" and MCycle = "001" and IRQCycle = '0' and NMICycle = '0' then
            PC <= PC + 1;
          end if;
          --
          -- jump control logic
          --
          case Jump is
            when "01" =>
              PC <= PC + 1;
            when "10" =>
              PC <= unsigned(DI & DL);
            when "11" =>
              -- LOCAL PATCH (ERRATA E-10).  Upstream fixes PCH in the SAME cycle
              -- it adds the displacement, and drives the address bus from
              -- PCAdder, so the branch target appears one cycle early and PC+2
              -- is never read.  A real 6502 reads PC+2 on cycle 3, THEN adds.
              -- So: update PCL here and remember the fixup for the next cycle.
              PC(7 downto 0) <= PCAdder(7 downto 0);
              if PCAdder(8) = '1' then
                if DL(7) = '0' then
                  PCHFix <= "01";
                else
                  PCHFix <= "10";
                end if;
              else
                PCHFix <= "00";
              end if;
            when others =>
              -- ...and apply it here, on the cycle that shows the un-fixed
              -- target on the bus.  Branch cycle 4 leaves Jump at "00", so this
              -- arm is the one that runs, and PCHFix is only ever non-zero for
              -- exactly that one cycle.
              if PCHFix /= "00" then
                if PCHFix = "01" then
                  PC(15 downto 8) <= PC(15 downto 8) + 1;
                else
                  PC(15 downto 8) <= PC(15 downto 8) - 1;
                end if;
                PCHFix <= "00";
              end if;
          end case;
        end if;
      end if;
    end if;
  end process;

  PCAdder <= resize(PC(7 downto 0),9) + resize(unsigned(DL(7) & DL),9) when PCAdd = '1'
         else "0" & PC(7 downto 0);

  process (Res_n_i, Clk)
    variable tmpP:std_logic_vector(7 downto 0);--Lets try to handle loading P at mcycle=0 and set/clk flags at same cycle
  begin
    if Res_n_i = '0' then
      P <= x"00"; -- ensure we have nothing set on reset
    elsif Clk'event and Clk = '1' then
      tmpP:=P;
      if (Enable = '1') then
        if (really_rdy = '1') then
          if MCycle = "000" then
            if LDA = '1' then
              ABC(7 downto 0) <= ALU_Q;
            end if;
            if LDX = '1' then
              X(7 downto 0) <= ALU_Q;
            end if;
            if LDY = '1' then
              Y(7 downto 0) <= ALU_Q;
            end if;
            if (LDA or LDX or LDY) = '1' then
              tmpP:=P_Out;
            end if;
          end if;
          if SaveP = '1' then
            tmpP:=P_Out;
          end if;
          if LDP = '1' then
            tmpP:=ALU_Q;
          end if;
          if IR(4 downto 0) = "11000" then
            case IR(7 downto 5) is
            when "000" =>--0x18(clc)
              tmpP(Flag_C) := '0';
            when "001" =>--0x38(sec)
              tmpP(Flag_C) := '1';
            when "010" =>--0x58(cli)
              tmpP(Flag_I) := '0';
            when "011" =>--0x78(sei)
              tmpP(Flag_I) := '1';
            when "101" =>--0xb8(clv)
              tmpP(Flag_V) := '0';
            when "110" =>--0xd8(cld)
              tmpP(Flag_D) := '0';
            when "111" =>--0xf8(sed)
              tmpP(Flag_D) := '1';
            when others =>
            end case;
          end if;
          tmpP(Flag_B) := '1';
          if IR = "00000000" and MCycle = "100" and RstCycle = '0' then
            --This should happen after P has been pushed to stack
            tmpP(Flag_I) := '1';
          end if;
          if SO_n_o = '1' and SO_n = '0' then
            tmpP(Flag_V) := '1';
          end if;
          if RstCycle = '1' then
            -- LOCAL PATCH (ERRATA E-51): reset SETS I (perfect6502: the first
            -- PHP after reset pushes I = 1) and leaves D alone -- clearing D
            -- on reset is a CMOS 65C02 change, not NMOS.  Upstream cleared both.
            tmpP(Flag_I) := '1';
          end if;
          tmpP(Flag_1) := '1';

          P<=tmpP;--new way

          SO_n_o <= SO_n;
        end if;
        -- LOCAL PATCH (ERRATA E-39): the die latches /IRQ (IRQP) every cycle,
        -- RDY or not, as upstream already did for /NMI below.
        if IR(4 downto 0)/="10000" or Jump/="01" then -- delay interrupts during branches (checked with Lorenz test and real 6510), not best way yet, though - but works...
          IRQ_n_o <= IRQ_n;
        end if;
        irq_raw_o <= IRQ_n;
        -- detect nmi even if not rdy
        if IR(4 downto 0)/="10000" or Jump/="01" then -- delay interrupts during branches (checked with Lorenz test and real 6510) not best way yet, though - but works...
          NMI_n_o <= NMI_n;
        end if;
      end if;
    end if;
  end process;

---------------------------------------------------------------------------
--
-- Buses
--
---------------------------------------------------------------------------

  process (Res_n_i, Clk)
  begin
    if Res_n_i = '0' then
      BusA_r <= (others => '0');
      BusB <= (others => '0');
      BusB_r <= (others => '0');
      AD <= (others => '0');
      BAL <= (others => '0');
      BAH <= (others => '0');
      DL <= (others => '0');
      SHCross <= '0';
    elsif Clk'event and Clk = '1' then
      if (Enable = '1') then
        if (really_rdy = '1') then
          -- LOCAL PATCH (ERRATA E-53): cleared on a step, not on every Enable.
          -- Upstream cleared it on every Enable, so a hold of the NMI vector's
          -- low-byte read forgot the hijack, and the high byte came from $FFFF
          -- (perfect6502: $FFFB).
          NMI_entered <= '0';
          if MCycle = "000" then
            SHCross <= '0';
          end if;
          BusA_r <= BusA;
          BusB <= DI;

          -- not really nice, but no better way found yet !
          if Set_Addr_To_r = Set_Addr_To_PBR or Set_Addr_To_r = Set_Addr_To_ZPG then
            BusB_r <= std_logic_vector(unsigned(DI(7 downto 0)) + 1); -- required for SHA
          end if;

          case BAAdd is
          when "01" =>
            -- BA Inc
            AD <= std_logic_vector(unsigned(AD) + 1);
            BAL <= std_logic_vector(unsigned(BAL) + 1);
          when "10" =>
            -- BA Add
            BAL <= std_logic_vector(resize(unsigned(BAL(7 downto 0)),9) + resize(unsigned(BusA),9));
          when "11" =>
            -- BA Adj
            if BAL(8) = '1' then
              BAH <= std_logic_vector(unsigned(BAH) + 1);
              SHCross <= '1';
            end if;
          when others =>
          end case;

          -- modified to use Y register as well
          if ADAdd = '1' then
            if (AddY = '1') then
              AD <= std_logic_vector(unsigned(AD) + unsigned(Y(7 downto 0)));
            else
              AD <= std_logic_vector(unsigned(AD) + unsigned(X(7 downto 0)));
            end if;
          end if;

          if IR = "00000000" then
            BAL <= (others => '1');
            BAH <= (others => '1');
            if RstCycle = '1' then
              BAL(2 downto 0) <= "100";
            elsif NMICycle = '1' or (NMIAct = '1' and MCycle="100") or NMI_entered='1' then
              BAL(2 downto 0) <= "010";
              if MCycle="100" then
                NMI_entered <= '1';
              end if;
            else
              BAL(2 downto 0) <= "110";
            end if;
            if Set_addr_To_r = Set_Addr_To_BA then
              BAL(0) <= '1';
            end if;
          end if;

          if LDDI = '1' then
            DL <= DI;
          end if;
          if LDALU = '1' then
            DL <= ALU_Q;
          end if;
          if LDAD = '1' then
            AD <= DI;
          end if;
          if LDBAL = '1' then
            BAL(7 downto 0) <= DI;
          end if;
          if LDBAH = '1' then
            BAH <= DI;
          end if;
        end if;
      end if;
    end if;
  end process;

  Break <= (BreakAtNA and not BAL(8)) or (PCAdd and not PCAdder(8));

  with Set_BusA_To select
    BusA <=
      DI                                    when Set_BusA_To_DI,
      ABC(7 downto 0)                       when Set_BusA_To_ABC,
      X(7 downto 0)                         when Set_BusA_To_X,
      Y(7 downto 0)                         when Set_BusA_To_Y,
      std_logic_vector(S(7 downto 0))       when Set_BusA_To_S,
      P                                     when Set_BusA_To_P,
      ABC(7 downto 0) and DI                when Set_BusA_To_DA,
      (ABC(7 downto 0) or x"ee") and DI     when Set_BusA_To_DAO,--ee for OAL instruction. constant may be different on other platforms.TODO:Move to generics
      -- LOCAL PATCH (ERRATA E-41): ANE/XAA's constant is $EF, and $EE when RDY
      -- held its operand cycle.  $EE breaks real C64 code: Spectipede's and
      -- Turrican 3's own ANE uses need bit 0 set.  VICE's testprogs CPU/ane
      -- (checked on a real C64C) pins both values.
      (ABC(7 downto 0) or ane_magic) and DI and X(7 downto 0)    when Set_BusA_To_DAX,
      ABC(7 downto 0) and X(7 downto 0)     when Set_BusA_To_AAX,--SAX, SHA
      (others => '-')                       when Set_BusA_To_DONTCARE;--Can probably remove this

  -- LOCAL PATCH (ERRATA E-52): SHA/SHX/SHY/TAS write on a page crossing to
  -- the byte they write, not to the carried high byte (perfect6502: 60
  -- cases, every crossing).  SHCross is set by any carry, but only these
  -- three write modes look at it.
  -- E-54: the page is the MASKED value even when an RDY hold dropped the mask
  -- from the data (perfect6502).
  BAH_eff <= sh_addr when SHCross = '1' and (Write_Data_r = Write_Data_AXB or
                     Write_Data_r = Write_Data_XB or Write_Data_r = Write_Data_YB)
             else BAH;
  with Write_Data_r select
    sh_addr <=
      ABC(7 downto 0) and X(7 downto 0) and BusB_r(7 downto 0) when Write_Data_AXB,
      X(7 downto 0) and BusB_r(7 downto 0) when Write_Data_XB,
      Y(7 downto 0) and BusB_r(7 downto 0) when others;

  with Set_Addr_To_r select
    A_i <=
      "0000000000000001" & std_logic_vector(S(7 downto 0))                            when Set_Addr_To_SP,
      DBR & "00000000" & AD                                                           when Set_Addr_To_ZPG,
      "00000000" & BAH_eff & BAL(7 downto 0)                                          when Set_Addr_To_BA,
      -- LOCAL PATCH (ERRATA E-10): PC, not PCAdder.  For every non-branch
      -- cycle PCAdd='0' and PCAdder is just PC(7 downto 0), so this changes
      -- nothing else; on a branch it stops the target reaching the bus a
      -- cycle early.
      PBR & std_logic_vector(PC(15 downto 8)) & std_logic_vector(PC(7 downto 0)) when Set_Addr_To_PBR;

  -- LOCAL PATCH (ERRATA E-11): the jammed bus.  Taken from the die, not from a
  -- guess: perfect6502 settles as $FFFF, $FFFE, $FFFE, then $FFFF FOR EVER.
  -- The two $FFFE cycles in the middle are a three-cycle transient, and a
  -- plausible-looking "$FFFE for ever" is wrong from the fourth cycle on.
  -- The bank byte is left alone so this stays a 6502-mode behaviour only.
  A <= A_i(23 downto 16) & x"FFFE"
         when (Jam = '1' and (JamPhase = "01" or JamPhase = "10")) else
       A_i(23 downto 16) & x"FFFF" when Jam = '1' else
       A_i;

  -- This is the P that gets pushed on stack with correct B flag. I'm not sure if NMI also clears B, but I guess it does.
  PwithB<=(P and x"ef") when (IRQCycle='1' or NMICycle='1') else P;

  -- LOCAL PATCH (ERRATA E-54): when RDY held the read step just before an
  -- SHA/SHX/SHY/TAS write, the die stores the register value WITHOUT the
  -- "and (high byte + 1)" term (perfect6502: only a hold of that one step has
  -- this effect; a hold of any earlier step does not).
  sh_mask <= x"FF" when sh_drop = '1' else BusB_r(7 downto 0);

  process (Res_n_i, Clk)
  begin
    if Res_n_i = '0' then
      sh_step_held <= '0';
      sh_drop <= '0';
    elsif Clk'event and Clk = '1' then
      if Enable = '1' then
        if really_rdy = '1' then
          sh_drop <= sh_step_held;
          sh_step_held <= '0';
        else
          sh_step_held <= '1';
        end if;
      end if;
    end if;
  end process;

  with Write_Data_r select
    DO <=
      DL                                  when Write_Data_DL,
      ABC(7 downto 0)                     when Write_Data_ABC,
      X(7 downto 0)                       when Write_Data_X,
      Y(7 downto 0)                       when Write_Data_Y,
      std_logic_vector(S(7 downto 0))     when Write_Data_S,
      PwithB                              when Write_Data_P,
      std_logic_vector(PC(7 downto 0))    when Write_Data_PCL,
      std_logic_vector(PC(15 downto 8))   when Write_Data_PCH,
      ABC(7 downto 0) and X(7 downto 0)   when Write_Data_AX,
      ABC(7 downto 0) and X(7 downto 0) and sh_mask when Write_Data_AXB, -- no better way found yet...
      X(7 downto 0) and sh_mask when Write_Data_XB, -- no better way found yet...
      Y(7 downto 0) and sh_mask when Write_Data_YB, -- no better way found yet...
      (others=>'-')                       when Write_Data_DONTCARE;--Can probably remove this


-------------------------------------------------------------------------
--
-- Main state machine
--
-------------------------------------------------------------------------

  process (Res_n_i, Clk)
  begin
    if Res_n_i = '0' then
      MCycle <= "001";
      RstCycle <= '1';
      IRQCycle <= '0';
      NMICycle <= '0';
      NMIAct <= '0';
      Jam <= '0';
      JamPhase <= "00";
      ane_held <= '0';
      t0_held <= '0';
      irq_req <= '0';
      nmi_req <= '0';
      br_irq <= '0';
      br_first <= '1';
    elsif Clk'event and Clk = '1' then
      if (Enable = '1') then
        if (really_rdy = '1') then
         ane_held <= '0';
         if Jam = '1' then
          -- LOCAL PATCH (ERRATA E-11): a jammed 6502 is STOPPED, not slowed.
          -- MCycle does not advance, so no further opcode is ever fetched, and
          -- interrupts are not started: on the die only RESET ends this state,
          -- and a JAM that could still be interrupted would be a NOP with extra
          -- steps.  JamPhase walks the address bus through the die's own
          -- settling sequence.
          if JamPhase /= "11" then
            JamPhase <= JamPhase + 1;
          end if;
         else
          if MCycle = "001" and IsJam = '1' then
            Jam <= '1';
          end if;
          if MCycle = LCycle or Break = '1' then
            MCycle <= "000";
            RstCycle <= '0';
            IRQCycle <= '0';
            NMICycle <= '0';
            if IR(4 downto 0) = "10000" and (MCycle = "001" or MCycle = "010") then
              -- LOCAL PATCH (ERRATA E-39): a branch that ends without crossing
              -- a page takes what its operand-cycle polls found (below); an
              -- untaken one ends ON the operand cycle, so this step's poll
              -- counts too.  NMI as upstream.
              if NMIAct = '1' and IR/=x"00" then
                NMICycle <= '1';
                NMIAct <= '0';
              elsif (MCycle = "010" and br_irq = '1') or
                    (MCycle = "001" and ((br_first = '0' and br_irq = '1') or
                                         (irq_raw_o = '0' and P(Flag_I) = '0'))) then
                IRQCycle <= '1';
              end if;
            elsif t0_held = '1' then
              -- LOCAL PATCH (ERRATA E-39): the last repeat of a T0 that RDY
              -- held.  It polls as the held repeats did (below), and what they
              -- found still stands.
              if nmi_req = '1' or NMIAct = '1' then
                NMICycle <= '1';
                NMIAct <= '0';
              elsif irq_req = '1' or (IRQ_n_o = '0' and I_eff = '0') then
                IRQCycle <= '1';
              end if;
            elsif NMIAct = '1' and IR/=x"00" then -- delay NMI further if we just executed a BRK
              NMICycle <= '1';
              NMIAct <= '0'; -- reset NMI edge detector if we start processing the NMI
            elsif IRQ_n_o = '0' and P(Flag_I) = '0' then
              IRQCycle <= '1';
            end if;
          else
            MCycle <= std_logic_vector(unsigned(MCycle) + 1);
          end if;
         end if;
         if MCycle = LCycle or Break = '1' then
           t0_held <= '0';
           br_first <= '1';
         end if;
        elsif Jam = '0' and (MCycle = LCycle or Break = '1') and IR(4 downto 0) /= "10000" then
          -- LOCAL PATCH (ERRATA E-39): THE DIE KEEPS POLLING WHILE RDY HOLDS T0.
          -- perfect6502 computes INTG = NMIG | (IRQP & !I) in phi2 of T0 -- an
          -- instruction's last cycle -- and RDY holding that cycle REPEATS it,
          -- so the poll is made again on every held repeat, with /IRQ as
          -- latched a cycle earlier and with I as it then stands: CLI and SEI
          -- write I in phi1 of the cycle AFTER their T0, which during a stall
          -- is the first held repeat.
          -- ⚠ THE POLL IS SET-ONLY ACROSS THE REPEATS.  The die clears INTG only
          -- when the vector is fetched, so a repeat that sees I = 1 (SEI) does
          -- not undo an earlier one that saw I = 0.  The first held repeat is
          -- the poll an unstalled T0 makes; every later one, and the step that
          -- finally completes (above), ORs in a poll with I as CLI/SEI wrote it.
          -- Branches poll at their operand cycle instead (the branch poll,
          -- below).
          if t0_held = '0' then
            if NMIAct = '1' and IR /= x"00" then nmi_req <= '1'; else nmi_req <= '0'; end if;
            if IRQ_n_o = '0' and P(Flag_I) = '0' then irq_req <= '1'; else irq_req <= '0'; end if;
          else
            if NMIAct = '1' then nmi_req <= '1'; end if;
            if IRQ_n_o = '0' and I_eff = '0' then irq_req <= '1'; end if;
          end if;
          t0_held <= '1';
          -- LOCAL PATCH (ERRATA E-41): RDY is holding ANE's operand cycle
          if IR = x"8B" then
            ane_held <= '1';
          end if;
        end if;
        -- LOCAL PATCH (ERRATA E-39): THE BRANCH POLL.  A branch decides on an
        -- IRQ at its OPERAND cycle (MCycle 1) -- which is why a taken branch
        -- delays an IRQ that arrives later -- and RDY holding that cycle repeats
        -- it, with a poll on every instance, each with /IRQ as latched in the
        -- cycle before (perfect6502: the window grows by exactly the hold).
        -- Holding a taken branch's third cycle changes nothing (perfect6502).
        -- Unstalled this is upstream's poll exactly: irq_raw_o at the end of
        -- the operand cycle is the sample from the end of the opcode fetch.
        if Jam = '0' and IR(4 downto 0) = "10000" and MCycle = "001" then
          if br_first = '1' then
            br_irq <= not irq_raw_o and not P(Flag_I);
          else
            br_irq <= br_irq or (not irq_raw_o and not P(Flag_I));
          end if;
          -- an untaken branch ends here: the next instruction starts afresh
          if really_rdy = '1' and (MCycle = LCycle or Break = '1') then
            br_first <= '1';
          else
            br_first <= '0';
          end if;
        end if;
        --detect NMI even if not rdy    
        if NMI_n_o = '1' and (NMI_n = '0' and (IR(4 downto 0)/="10000" or Jump/="01")) then -- branches have influence on NMI start (not best way yet, though - but works...)
          NMIAct <= '1';
        end if;
        -- we entered NMI during BRK instruction
        if NMI_entered='1' then
          NMIAct <= '0';
        end if;
      end if;
    end if;
  end process;

end;

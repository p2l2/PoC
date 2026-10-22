-- =============================================================================
-- Authors:           Stefan Unrein
--
-- Entity:            AXI4 Multiplexer
--
-- Description:
-- -------------------------------------
-- The module provides a multiplexing function between generic
-- AXI4 channel to one AXI4 channel.
-- The output ID of a transaction is the input port number concatenated with
-- its input ID (port & ID), so the output ID has to be at least
-- log2(ports) bits wider than the input ID. A response is routed back by the
-- port bits of its ID and forwarded with the input ID. Transactions of one
-- port with one ID keep one output ID, so the subordinate's ordering rules
-- for an ID hold per port as well. Nothing limits the number of outstanding
-- transactions, that is up to the managers and the subordinate.
-- PIPELINE_IN and PIPELINE_OUT provide the settings for input and ouput
-- pipelining stages as a timing relaxantion setting.
-- The inputs are arbitrated in a round-robin fashion for all active data
-- channels.
--
-- Utilization compared to Xilinx Crossbar (2.1) 4 Slave => 1 Master (32 Addr/Data)
-- | LUT  | FF   | Comment                |
-- | ---- | ---- | ---------------------- |
-- | 439  | 349  | Xilinx Crosbar ( 2 IDs)|
-- | 953  | 688  | Xilinx Crosbar (16 IDs)|
-- | 309  | 21   | 0 Glue   ( 2 IDs)      |
-- | 447  | 55   | 0 Glue   (16 IDs)      |
--
--
-- License:
-- =============================================================================
-- Copyright 2025-2026 The PoC-Library Authors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--        http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- =============================================================================

library IEEE;
use     IEEE.std_logic_1164.all;
use     IEEE.numeric_std.all;

use     work.utils.all;
use     work.vectors.all;
use     work.components.all;
use     work.axi4_Full.all;
use     work.axi4stream.all;

entity axi4_Mux is
	generic(
		PIPELINE_IN            : natural_vector  := (0 => 0);
		PIPELINE_OUT           : natural   := 0
	);
	port (
		Clock             : in  std_logic;
		Reset             : in  std_logic;
		-- IN Port
		In_M2S            : in  T_AXI4_Bus_M2S_VECTOR;
		In_S2M            : out T_AXI4_Bus_S2M_VECTOR;
		-- OUT Port
		Out_M2S           : out T_AXI4_Bus_M2S;
		Out_S2M           : in  T_AXI4_Bus_S2M
	);
end entity;

architecture rtl of axi4_Mux is
	constant PORTS     : positive := In_M2S'length;
	constant PORT_BITS : positive := log2ceilnz(PORTS);

	constant IN_AW_ID_BITS    : natural := In_M2S(In_M2S'low).AWID'length;
	constant Out_AW_ID_BITS   : natural := Out_M2S.AWID'length;
	constant IN_AR_ID_BITS    : natural := In_M2S(In_M2S'low).ARID'length;
	constant Out_AR_ID_BITS   : natural := Out_M2S.ARID'length;
	-- constant ADDRESS_BITS     : natural := In_M2S(In_M2S'low).AWAddr'length;
	-- constant DATA_BITS        : natural := Out_M2S.WData'length;

	signal In_M2S_g     : In_M2S'subtype;
	signal In_S2M_g     : In_S2M'subtype;
	signal In_M2S_write : In_M2S'subtype;
	signal In_S2M_write : In_S2M'subtype;
	signal In_M2S_read  : In_M2S'subtype;
	signal In_S2M_read  : In_S2M'subtype;

	signal Out_M2S_g     : Out_M2S'subtype;
	signal Out_S2M_g     : Out_S2M'subtype;
	signal Out_M2S_write : Out_M2S'subtype;
	signal Out_S2M_write : Out_S2M'subtype;
	signal Out_M2S_read  : Out_M2S'subtype;
	signal Out_S2M_read  : Out_S2M'subtype;

begin
	assert In_M2S(In_M2S'low).AWAddr'length = Out_M2S.AWAddr'length report "PoC.axi4_Mux:: AWAddr size of in and out not matching!" severity failure;
	assert In_M2S(In_M2S'low).ARAddr'length = Out_M2S.ARAddr'length report "PoC.axi4_Mux:: ARAddr size of in and out not matching!" severity failure;
	assert In_M2S(In_M2S'low).WData'length = Out_M2S.WData'length   report "PoC.axi4_Mux:: WData size of in and out not matching!" severity failure;
	assert In_S2M(In_M2S'low).RData'length = Out_S2M.RData'length   report "PoC.axi4_Mux:: RData size of in and out not matching!" severity failure;
	-- assert In_S2M(In_M2S'low).AWID'length  = Out_S2M.BID'length     report "PoC.axi4_Mux:: Write ID size of in and out not matching!" severity failure;
	-- assert In_S2M(In_M2S'low).ARID'length  = Out_S2M.RID'length     report "PoC.axi4_Mux:: Read ID size of in and out not matching!" severity failure;
	assert PIPELINE_IN'length = PORTS                               report "PoC.axi4_Mux:: PIPELINE_IN-Length is not equal to Number Port-Vector!" severity failure;
	assert Out_AW_ID_BITS >= PORT_BITS + IN_AW_ID_BITS              report "PoC.axi4_Mux:: Output AWID must be log2(ports) bits wider than the input AWID!" severity failure;
	assert Out_AR_ID_BITS >= PORT_BITS + IN_AR_ID_BITS              report "PoC.axi4_Mux:: Output ARID must be log2(ports) bits wider than the input ARID!" severity failure;

	glue_in_loop_gen : for i in In_M2S'range generate
		glue_in_gen : if PIPELINE_IN(i) > 0 generate
			Glue_in : entity work.axi4_FIFO
			generic map(
				FRAMES            => PIPELINE_IN(i) -1
			)
			port map(
				Clock             => Clock,
				Reset             => Reset,
				-- IN Port
				In_M2S            => In_M2S(i),
				In_S2M            => In_S2M(i),
				-- OUT Port
				Out_M2S           => In_M2S_g(i),
				Out_S2M           => In_S2M_g(i)
			);
		else generate
			In_M2S_g(i) <= In_M2S(i);
			In_S2M(i)   <= In_S2M_g(i);
		end generate;
	end generate;

	glue_out_gen : if PIPELINE_OUT > 0 generate
		Glue_out : entity work.axi4_FIFO
		generic map(
			FRAMES            => PIPELINE_OUT -1
		)
		port map(
			Clock             => Clock,
			Reset             => Reset,
			-- IN Port
			In_M2S            => Out_M2S_g,
			In_S2M            => Out_S2M_g,
			-- OUT Port
			Out_M2S           => Out_M2S,
			Out_S2M           => Out_S2M
		);
	else generate
		Out_M2S   <= Out_M2S_g;
		Out_S2M_g <= Out_S2M;
	end generate;

	write_blk : block
		type T_STATE is (ST_Idle, ST_Dataflow, ST_DataOnly, ST_AddressOnly);

		signal State     : T_STATE := ST_Idle;
		signal NextState : T_STATE;

		signal Arbitrate     : std_logic;
		signal RequestVector : std_logic_vector(PORTS - 1 downto 0);
		signal Arbitrated    : std_logic;
		signal GrantVector   : std_logic_vector(PORTS - 1 downto 0);
		signal GrantIndex    : unsigned(log2ceilnz(PORTS) - 1 downto 0);

		signal RequestWithSelf    : std_logic;
		signal RequestWithoutSelf : std_logic;
	begin
		assign_gen : for i in 0 to PORTS - 1 generate
			RequestVector(i) <= In_M2S_write(i).AWValid and In_M2S_write(i).WValid;
		end generate;

		RequestWithSelf    <= slv_or(RequestVector);
		RequestWithoutSelf <= slv_or(RequestVector and not GrantVector);

		process(Clock)
		begin
			if rising_edge(Clock) then
				if (Reset = '1') then
					State <= ST_Idle;
				else
					State <= NextState;
				end if;
			end if;
		end process;

		-- One burst at a time on AW and W, as W has no ID to tell bursts apart.
		-- Write responses are routed by BID independently of that.
		process(all)
			variable writeResponseIndex : natural;
		begin
			NextState <= State;

			In_S2M_write  <= (In_S2M'range => Initialize_AXI4_Bus_S2M(Out_S2M.RData'length, Out_S2M.RUser'length, In_S2M(In_S2M'low).BID'length, '0'));
			Out_M2S_write <= Initialize_AXI4_Bus_M2S(Out_M2S.AWAddr'length, Out_M2S.WData'length, Out_M2S.WUser'length, Out_M2S.AWID'length, '0');

			Arbitrate <= '0';

			case State is
				when ST_Idle =>
					if RequestWithSelf = '1' then
						Arbitrate <= '1';
						NextState <= ST_Dataflow;
					end if;

				when ST_Dataflow =>
					-- Arbitrated is always set a clock cycle after request
					Out_M2S_write      <= IDResize(In_M2S_write(to_integer(GrantIndex)), Out_AW_ID_BITS, Out_AR_ID_BITS);
					In_S2M_write(to_integer(GrantIndex)) <= IDResize(Out_S2M_write, In_AW_ID_BITS, In_AR_ID_BITS);

					if (Out_S2M_write.AWReady and In_M2S_write(to_integer(GrantIndex)).WValid and In_M2S_write(to_integer(GrantIndex)).WLast and Out_S2M_write.WReady) = '1' then --Write Data and Address finished at the same time, AW Valid was set and checked in Idle state
						if RequestWithoutSelf = '1' then
							Arbitrate <= '1';
						else
							NextState <= ST_Idle;
						end if;

					elsif Out_S2M_write.AWReady = '1' then -- We transmitted the Write Address
						NextState <= ST_DataOnly;

					elsif (In_M2S_write(to_integer(GrantIndex)).WValid and In_M2S_write(to_integer(GrantIndex)).WLast and Out_S2M_write.WReady) = '1' then -- We transmitted the Write Data
						NextState <= ST_AddressOnly;
					end if;

				when ST_DataOnly =>
					Out_M2S_write      <= IDResize(In_M2S_write(to_integer(GrantIndex)), Out_AW_ID_BITS, Out_AR_ID_BITS);
					Out_M2S_write.AWValid <= '0';
					In_S2M_write(to_integer(GrantIndex)) <= IDResize(Out_S2M_write, In_AW_ID_BITS, In_AR_ID_BITS);
					In_S2M_write(to_integer(GrantIndex)).AWReady <= '0';

					if (In_M2S_write(to_integer(GrantIndex)).WValid and In_M2S_write(to_integer(GrantIndex)).WLast and Out_S2M_write.WReady) = '1' then -- We transmitted the Write Data
						if RequestWithoutSelf = '1' then -- We have another request that can be processed immediately
							Arbitrate <= '1';
							NextState <= ST_Dataflow;
						else
							NextState <= ST_Idle;
						end if;
					end if;

				when ST_AddressOnly =>
					Out_M2S_write      <= IDResize(In_M2S_write(to_integer(GrantIndex)), Out_AW_ID_BITS, Out_AR_ID_BITS);
					Out_M2S_write.WValid <= '0';
					In_S2M_write(to_integer(GrantIndex)) <= IDResize(Out_S2M_write, In_AW_ID_BITS, In_AR_ID_BITS);
					In_S2M_write(to_integer(GrantIndex)).WReady <= '0';

					if Out_S2M_write.AWReady = '1' then -- We transmitted the Write Address
						if RequestWithoutSelf = '1' then
							Arbitrate <= '1';
							NextState <= ST_Dataflow;
						else
							NextState <= ST_Idle;
						end if;
					end if;
			end case;

			-- Output AWID is port & input AWID
			Out_M2S_write.AWID <= std_logic_vector(resize(GrantIndex & unsigned(In_M2S_write(to_integer(GrantIndex)).AWID), Out_AW_ID_BITS));

			-- Handle write response, routed by the port bits of BID
			writeResponseIndex := to_integer(unsigned(Out_S2M_write.BID(PORT_BITS + In_AW_ID_BITS -1 downto In_AW_ID_BITS)));

			for i in 0 to PORTS -1 loop -- Write response data can stay always the same
				In_S2M_write(i).BID    <= Out_S2M_write.BID(In_AW_ID_BITS -1 downto 0);
				In_S2M_write(i).BResp  <= Out_S2M_write.BResp;
				In_S2M_write(i).BUser  <= Out_S2M_write.BUser;
				In_S2M_write(i).BValid <= '0';
			end loop;

			Out_M2S_write.BReady <= '0';
			if writeResponseIndex < PORTS then
				In_S2M_write(writeResponseIndex).BValid <= Out_S2M_write.BValid;
				Out_M2S_write.BReady <= In_M2S_write(writeResponseIndex).BReady;
			end if;
		end process;

		Arbiter : entity work.bus_Arbiter
		generic map(
			STRATEGY   => "RR",
			PORTS      => PORTS,
			OUTPUT_REG => TRUE
		)
		port map(
			Clock => Clock,
			Reset => Reset,

			Arbitrate     => Arbitrate,
			RequestVector => RequestVector,

			Arbitrated  => Arbitrated,
			GrantVector => GrantVector,
			GrantIndex  => GrantIndex
		);
	end block;

	read_blk : block
		constant AR_Addr_POS    : natural := 0;
		constant AR_Len_POS     : natural := 1;
		constant AR_Size_POS    : natural := 2;
		constant AR_Burst_POS   : natural := 3;
		constant AR_ID_POS      : natural := 4;
		constant AR_User_POS    : natural := 5;
		constant AR_Cache_POS   : natural := 6;
		constant AR_Protect_POS : natural := 7;
		constant AR_Lock_POS    : natural := 8;
		constant AR_QoS_POS     : natural := 9;
		constant AR_Region_POS  : natural := 10;

		constant FORWARD_BIT_VEC : positive_vector := (
			AR_Addr_POS    => Out_M2S.ARAddr'length,
			AR_Len_POS     => Out_M2S.ARLen'length,
			AR_Size_POS    => Out_M2S.ARSize'length,
			AR_Burst_POS   => Out_M2S.ARBurst'length,
			AR_ID_POS      => Out_M2S.ARID'length,
			AR_User_POS    => Out_M2S.ARUser'length,
			AR_Cache_POS   => Out_M2S.ARCache'length,
			AR_Protect_POS => Out_M2S.ARProt'length,
			AR_Lock_POS    => Out_M2S.ARLock'length,
			AR_QoS_POS     => Out_M2S.ARQoS'length,
			AR_Region_POS  => Out_M2S.ARRegion'length
		);

		-- IN Ports
		signal Mux_In_M2S : T_AXI4Stream_M2S_VECTOR(PORTS - 1 downto 0)(Data(isum(FORWARD_BIT_VEC) - 1 downto 0), Keep(0 downto 0), User(0 downto 0), ID(0 downto 0), Dest(0 downto 0));
		signal Mux_In_S2M : T_AXI4Stream_S2M_VECTOR(PORTS - 1 downto 0)(User(0 downto 0));
		-- OUT Ports
		signal Mux_Out_M2S : T_AXI4Stream_M2S(Data(isum(FORWARD_BIT_VEC) - 1 downto 0), Keep(0 downto 0), User(0 downto 0), ID(0 downto 0), Dest(0 downto 0));
		signal Mux_Out_S2M : T_AXI4Stream_S2M(User(0 downto 0));

		-- Port of the read response, from the port bits of RID
		signal ResponsePort : unsigned(PORT_BITS - 1 downto 0);

	begin
		ResponsePort <= unsigned(Out_S2M_read.RID(PORT_BITS + In_AR_ID_BITS - 1 downto In_AR_ID_BITS));

		assign_gen : for i in 0 to PORTS - 1 generate

			signal ForwardDataIn : std_logic_vector(isum(FORWARD_BIT_VEC) - 1 downto 0);

			alias Mux_Valid : std_logic is Mux_In_M2S(i).Valid;
			alias Mux_Ready : std_logic is Mux_In_S2M(i).Ready;
			-- alias Mux_SoF   : std_logic is Mux_In_M2S(i).SoF;
			alias Mux_Last  : std_logic is Mux_In_M2S(i).Last;

			alias Mux_ARValid : std_logic is In_M2S_read(i).ARValid;
			alias Mux_RReady  : std_logic is In_M2S_read(i).RReady;

			signal Mux_ARReady : std_logic;
			signal Mux_RValid  : std_logic;
			signal Mux_RLast   : std_logic;

			signal Is_Packet : std_logic := '0';

		begin
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Addr_POS   ) downto low(FORWARD_BIT_VEC, AR_Addr_POS   )) <= resize(In_M2S_read(i).ARAddr, FORWARD_BIT_VEC(AR_Addr_POS));
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Len_POS    ) downto low(FORWARD_BIT_VEC, AR_Len_POS    )) <= In_M2S_read(i).ARLen;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Size_POS   ) downto low(FORWARD_BIT_VEC, AR_Size_POS   )) <= In_M2S_read(i).ARSize;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Burst_POS  ) downto low(FORWARD_BIT_VEC, AR_Burst_POS  )) <= In_M2S_read(i).ARBurst;
			-- Output ARID is port & input ARID
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_ID_POS     ) downto low(FORWARD_BIT_VEC, AR_ID_POS     )) <= std_logic_vector(resize(to_unsigned(i, PORT_BITS) & unsigned(In_M2S_read(i).ARID), Out_AR_ID_BITS));
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_User_POS   ) downto low(FORWARD_BIT_VEC, AR_User_POS   )) <= In_M2S_read(i).ARUser;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Cache_POS  ) downto low(FORWARD_BIT_VEC, AR_Cache_POS  )) <= In_M2S_read(i).ARCache;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Protect_POS) downto low(FORWARD_BIT_VEC, AR_Protect_POS)) <= In_M2S_read(i).ARProt;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Lock_POS   ) downto low(FORWARD_BIT_VEC, AR_Lock_POS   )) <= In_M2S_read(i).ARLock;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_QoS_POS    ) downto low(FORWARD_BIT_VEC, AR_QoS_POS    )) <= In_M2S_read(i).ARQoS;
			ForwardDataIn(high(FORWARD_BIT_VEC, AR_Region_POS ) downto low(FORWARD_BIT_VEC, AR_Region_POS )) <= In_M2S_read(i).ARRegion;

			Mux_In_M2S(i).Data <= ForwardDataIn;

			In_S2M_read(i).ARReady <= Mux_Ready;

			Mux_Valid <= In_M2S_read(i).ARValid;
			-- Mux_SoF   <= '1';
			Mux_Last  <= '1';

			In_S2M_read(i).RLast  <= Out_S2M_read.RLast;
			In_S2M_read(i).RData  <= Out_S2M_read.RData;
			In_S2M_read(i).RResp  <= Out_S2M_read.RResp;
			In_S2M_read(i).RUser  <= Out_S2M_read.RUser;
			In_S2M_read(i).RID    <= Out_S2M_read.RID(In_AR_ID_BITS - 1 downto 0);
			In_S2M_read(i).RValid <= Out_S2M_read.RValid and to_sl(ResponsePort = i);

		end generate;

		process(all)
		begin
			-- Address Read assignment
			Out_M2S_read.ARValid  <= Mux_Out_M2S.Valid;
			Out_M2S_read.ARAddr   <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Addr_POS   ) downto low(FORWARD_BIT_VEC, AR_Addr_POS   ));
			Out_M2S_read.ARLen    <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Len_POS    ) downto low(FORWARD_BIT_VEC, AR_Len_POS    ));
			Out_M2S_read.ARSize   <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Size_POS   ) downto low(FORWARD_BIT_VEC, AR_Size_POS   ));
			Out_M2S_read.ARBurst  <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Burst_POS  ) downto low(FORWARD_BIT_VEC, AR_Burst_POS  ));
			Out_M2S_read.ARID     <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_ID_POS     ) downto low(FORWARD_BIT_VEC, AR_ID_POS     ));
			Out_M2S_read.ARUser   <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_User_POS   ) downto low(FORWARD_BIT_VEC, AR_User_POS   ));
			Out_M2S_read.ARCache  <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Cache_POS  ) downto low(FORWARD_BIT_VEC, AR_Cache_POS  ));
			Out_M2S_read.ARProt   <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Protect_POS) downto low(FORWARD_BIT_VEC, AR_Protect_POS));
			Out_M2S_read.ARLock   <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Lock_POS   ) downto low(FORWARD_BIT_VEC, AR_Lock_POS   ));
			Out_M2S_read.ARQoS    <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_QoS_POS    ) downto low(FORWARD_BIT_VEC, AR_QoS_POS    ));
			Out_M2S_read.ARRegion <= Mux_Out_M2S.Data(high(FORWARD_BIT_VEC, AR_Region_POS ) downto low(FORWARD_BIT_VEC, AR_Region_POS ));

			-- Read response ready, from the port of RID
			if to_integer(ResponsePort) < PORTS then
				Out_M2S_read.RReady <= In_M2S_read(to_integer(ResponsePort)).RReady;
			else
				Out_M2S_read.RReady <= '0';
			end if;
		end process;

		Read_mux : entity work.axi4stream_Mux
		generic map(
			PORTS => PORTS
		)
		port map(
			Clock => Clock,
			Reset => Reset,
			-- IN Ports
			In_M2S => Mux_In_M2S,
			In_S2M => Mux_In_S2M,
			-- OUT Port
			Out_M2S => Mux_Out_M2S,
			Out_S2M => Mux_Out_S2M
		);
		Mux_Out_S2M.Ready <= Out_S2M_read.ARReady;
	end block;


	assign_gen : for i in 0 to PORTS - 1 generate
		In_M2S_write(i).AWID     <= In_M2S_g(i).AWID    ;
		In_M2S_write(i).AWAddr   <= In_M2S_g(i).AWAddr  ;
		In_M2S_write(i).AWLen    <= In_M2S_g(i).AWLen   ;
		In_M2S_write(i).AWSize   <= In_M2S_g(i).AWSize  ;
		In_M2S_write(i).AWBurst  <= In_M2S_g(i).AWBurst ;
		In_M2S_write(i).AWLock   <= In_M2S_g(i).AWLock  ;
		In_M2S_write(i).AWQOS    <= In_M2S_g(i).AWQOS   ;
		In_M2S_write(i).AWRegion <= In_M2S_g(i).AWRegion;
		In_M2S_write(i).AWUser   <= In_M2S_g(i).AWUser  ;
		In_M2S_write(i).AWValid  <= In_M2S_g(i).AWValid ;
		In_M2S_write(i).AWCache  <= In_M2S_g(i).AWCache ;
		In_M2S_write(i).AWProt   <= In_M2S_g(i).AWProt  ;
		In_M2S_write(i).WValid   <= In_M2S_g(i).WValid  ;
		In_M2S_write(i).WLast    <= In_M2S_g(i).WLast   ;
		In_M2S_write(i).WUser    <= In_M2S_g(i).WUser   ;
		In_M2S_write(i).WData    <= In_M2S_g(i).WData   ;
		In_M2S_write(i).WStrb    <= In_M2S_g(i).WStrb   ;
		In_M2S_write(i).BReady   <= In_M2S_g(i).BReady  ;
		In_M2S_read(i).ARValid   <= In_M2S_g(i).ARValid ;
		In_M2S_read(i).ARAddr    <= In_M2S_g(i).ARAddr  ;
		In_M2S_read(i).ARCache   <= In_M2S_g(i).ARCache ;
		In_M2S_read(i).ARProt    <= In_M2S_g(i).ARProt  ;
		In_M2S_read(i).ARID      <= In_M2S_g(i).ARID    ;
		In_M2S_read(i).ARLen     <= In_M2S_g(i).ARLen   ;
		In_M2S_read(i).ARSize    <= In_M2S_g(i).ARSize  ;
		In_M2S_read(i).ARBurst   <= In_M2S_g(i).ARBurst ;
		In_M2S_read(i).ARLock    <= In_M2S_g(i).ARLock  ;
		In_M2S_read(i).ARQOS     <= In_M2S_g(i).ARQOS   ;
		In_M2S_read(i).ARRegion  <= In_M2S_g(i).ARRegion;
		In_M2S_read(i).ARUser    <= In_M2S_g(i).ARUser  ;
		In_M2S_read(i).RReady    <= In_M2S_g(i).RReady  ;

		In_S2M_g(i).AWReady      <= In_S2M_write(i).AWReady;
		In_S2M_g(i).WReady       <= In_S2M_write(i).WReady ;
		In_S2M_g(i).BValid       <= In_S2M_write(i).BValid ;
		In_S2M_g(i).BResp        <= In_S2M_write(i).BResp  ;
		In_S2M_g(i).BID          <= In_S2M_write(i).BID    ;
		In_S2M_g(i).BUser        <= In_S2M_write(i).BUser  ;
		In_S2M_g(i).ARReady      <= In_S2M_read(i).ARReady ;
		In_S2M_g(i).RValid       <= In_S2M_read(i).RValid  ;
		In_S2M_g(i).RData        <= In_S2M_read(i).RData   ;
		In_S2M_g(i).RResp        <= In_S2M_read(i).RResp   ;
		In_S2M_g(i).RID          <= In_S2M_read(i).RID     ;
		In_S2M_g(i).RLast        <= In_S2M_read(i).RLast   ;
		In_S2M_g(i).RUser        <= In_S2M_read(i).RUser   ;
	end generate;

	Out_M2S_g.AWID     <= Out_M2S_write.AWID    ;
	Out_M2S_g.AWAddr   <= Out_M2S_write.AWAddr  ;
	Out_M2S_g.AWLen    <= Out_M2S_write.AWLen   ;
	Out_M2S_g.AWSize   <= Out_M2S_write.AWSize  ;
	Out_M2S_g.AWBurst  <= Out_M2S_write.AWBurst ;
	Out_M2S_g.AWLock   <= Out_M2S_write.AWLock  ;
	Out_M2S_g.AWQOS    <= Out_M2S_write.AWQOS   ;
	Out_M2S_g.AWRegion <= Out_M2S_write.AWRegion;
	Out_M2S_g.AWUser   <= Out_M2S_write.AWUser  ;
	Out_M2S_g.AWValid  <= Out_M2S_write.AWValid ;
	Out_M2S_g.AWCache  <= Out_M2S_write.AWCache ;
	Out_M2S_g.AWProt   <= Out_M2S_write.AWProt  ;
	Out_M2S_g.WValid   <= Out_M2S_write.WValid  ;
	Out_M2S_g.WLast    <= Out_M2S_write.WLast   ;
	Out_M2S_g.WUser    <= Out_M2S_write.WUser   ;
	Out_M2S_g.WData    <= Out_M2S_write.WData   ;
	Out_M2S_g.WStrb    <= Out_M2S_write.WStrb   ;
	Out_M2S_g.BReady   <= Out_M2S_write.BReady  ;
	Out_M2S_g.ARValid  <= Out_M2S_read.ARValid ;
	Out_M2S_g.ARAddr   <= Out_M2S_read.ARAddr  ;
	Out_M2S_g.ARCache  <= Out_M2S_read.ARCache ;
	Out_M2S_g.ARProt   <= Out_M2S_read.ARProt  ;
	Out_M2S_g.ARID     <= Out_M2S_read.ARID    ;
	Out_M2S_g.ARLen    <= Out_M2S_read.ARLen   ;
	Out_M2S_g.ARSize   <= Out_M2S_read.ARSize  ;
	Out_M2S_g.ARBurst  <= Out_M2S_read.ARBurst ;
	Out_M2S_g.ARLock   <= Out_M2S_read.ARLock  ;
	Out_M2S_g.ARQOS    <= Out_M2S_read.ARQOS   ;
	Out_M2S_g.ARRegion <= Out_M2S_read.ARRegion;
	Out_M2S_g.ARUser   <= Out_M2S_read.ARUser  ;
	Out_M2S_g.RReady   <= Out_M2S_read.RReady  ;

	Out_S2M_write.AWReady <= Out_S2M_g.AWReady;
	Out_S2M_write.WReady  <= Out_S2M_g.WReady ;
	Out_S2M_write.BValid  <= Out_S2M_g.BValid ;
	Out_S2M_write.BResp   <= Out_S2M_g.BResp  ;
	Out_S2M_write.BID     <= Out_S2M_g.BID    ;
	Out_S2M_write.BUser   <= Out_S2M_g.BUser  ;
	Out_S2M_read.ARReady  <= Out_S2M_g.ARReady;
	Out_S2M_read.RValid   <= Out_S2M_g.RValid ;
	Out_S2M_read.RData    <= Out_S2M_g.RData  ;
	Out_S2M_read.RResp    <= Out_S2M_g.RResp  ;
	Out_S2M_read.RID      <= Out_S2M_g.RID    ;
	Out_S2M_read.RLast    <= Out_S2M_g.RLast  ;
	Out_S2M_read.RUser    <= Out_S2M_g.RUser  ;
end architecture;

-- =============================================================================
-- Authors:
--  Alexander Daum (P2L2 GmbH)
--
-- Test that the AxiMux keeps transactions of one Manager with the same in-order
-- when the Subordinate re-orders between IDs
--
-- This test only tests valid AXI-4 behavior when the internal TransactionsRange length is less than or equal to
-- the number of IDs provided by the Mux (2**ID_width when Transactions generic is the default 0)
--
-- License:
-- =============================================================================
-- Copyright 2026 The PoC-Library Authors
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

library OSVVM;
context OSVVM.OsvvmContext;

library OSVVM_AXI4;
context OSVVM_AXI4.Axi4Context;

library PoC;
use     PoC.utils.all;

architecture SimpleReadOutOfOrder of TestControl is
	signal TestDone : integer_barrier := 1;

	type ReadResponseDataType is record
	    address : std_ulogic_vector(31 downto 0);
			id: natural;
	end record;

	subtype TransactionsRange is integer range 0 to 1;
	type ReadResponseBufferType is array (TransactionsRange) of ReadResponseDataType;

begin

	------------------------------------------------------------
	-- ControlProc
	-- Set up AlertLog and wait for end of test
	------------------------------------------------------------
	ControlProc : process
		constant TestName : string := "TC_SimpleReadOutOfOrder";
	begin
		-- Initialization of test
		SetTestName(TestName);
		TranscriptOpen;
		SetTranscriptMirror(TRUE);

		SetLogEnable(PASSED, FALSE);  -- Enable PASSED logs
		SetLogEnable(INFO, FALSE);    -- Enable INFO logs

		-- Wait for testbench initialization

		-- Wait for Design Reset
		wait until Reset = '0';
		ClearAlerts;

		-- Wait for test to finish
		WaitForBarrier(TestDone);
		AlertIf(now >= 10 ms, "Test finished due to timeout");
		--    AlertIf(GetAffirmCount < 100, "Test is not Self-Checking");

		wait for 1 us;

		EndOfTestReports(ReportAll => TRUE);
		TranscriptClose;
		std.env.stop;
		wait;
	end process ControlProc;


		ManagerProc : process
		begin
			wait until Reset = '0';
			WaitForClock(AXI4_Manager_Transaction(0), 2);

			-- Manager only using one ID, transactions must complete in order
			for i in TransactionsRange loop
				ReadAddressAsync(AXI4_Manager_Transaction(0), std_ulogic_vector(to_unsigned(i * 4, 32)));
			end loop;

			for i in TransactionsRange loop
				ReadCheckData(AXI4_Manager_Transaction(0), std_ulogic_vector(to_unsigned(i * 4, 32)));
			end loop;

			WaitForClock(AXI4_Manager_Transaction(0), 2);

			wait for 100 ns;
			WaitForBarrier(TestDone);
			wait;
		end process;

	ResponderProc : process
		variable Address  : std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
		variable Available : boolean;
		variable ID        : natural;

		variable TransactionsReceived : integer := 0;
		variable ReadResponseBuffer : ReadResponseBufferType;
	begin
		wait until Reset = '0';
		WaitForClock(AXI4_Subordinate_Transaction, 2);

		-- Collect all Transactions
		while TransactionsReceived < ReadResponseBuffer'length loop
			TryGetReadAddress(AXI4_Subordinate_Transaction, Address, Available);
			if Available then
				GetAxi4Options(AXI4_Subordinate_Transaction, ARID, ID);
				ReadResponseBuffer(TransactionsReceived) := (address => Address, id => ID);
				TransactionsReceived := TransactionsReceived + 1;
			end if;
			WaitForClock(AXI4_Subordinate_Transaction);
		end loop;

		-- Send out in reverse order
		for i in ReadResponseBuffer'reverse_range loop
			SetAxi4Options(AXI4_Subordinate_Transaction, RID, ReadResponseBuffer(i).id);
			SendReadData(AXI4_Subordinate_Transaction, ReadResponseBuffer(i).address);
		end loop;

		wait;
	end process;

end architecture;

configuration TC_SimpleReadOutOfOrder of axi4_Mux_TestHarness is
	for Harness
		for TestControl_inst : TestControl
			use entity work.TestControl(SimpleReadOutOfOrder);
		end for;
	end for;
end configuration;

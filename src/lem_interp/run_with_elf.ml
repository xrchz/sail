open Printf ;;
open Big_int ;;
open Interp_ast ;;
open Interp_interface ;;
open Interp_inter_imp ;;
open Run_interp_model ;;

open Sail_interface ;;

module StringMap = Map.Make(String)

let file = ref "" ;;

let rec foldli f acc ?(i=0) = function
  | [] -> acc
  | x::xs -> foldli f (f i acc x) ~i:(i+1) xs
;;

let endian = ref E_big_endian ;;

let hex_to_big_int s = big_int_of_int64 (Int64.of_string s) ;;

let data_mem = (ref Mem.empty : (memory_byte Run_interp_model.Mem.t) ref) ;;
let prog_mem = (ref Mem.empty : (memory_byte Run_interp_model.Mem.t) ref) ;;
let reg = ref Reg.empty ;;

let add_mem byte addr mem =
  assert(byte >= 0 && byte < 256);
  (*Printf.printf "adder is %s, byte is %s\n" (string_of_big_int addr) (string_of_int byte);*)
  let mem_byte = memory_byte_of_int byte in
  mem := Mem.add addr mem_byte !mem

let get_reg reg name =
  let reg_content = Reg.find name reg in reg_content

let rec load_memory_segment' (bytes,addr) mem =
  match bytes with
  | [] -> ()
  | byte::bytes' ->
    let data_byte = Char.code byte in
    let addr' = Nat_big_num.succ addr in
    begin add_mem data_byte addr mem;
      load_memory_segment' (bytes',addr') mem
    end

let rec load_memory_segment (segment: Elf_interpreted_segment.elf64_interpreted_segment) mem =
  let (Byte_sequence.Sequence bytes) = segment.Elf_interpreted_segment.elf64_segment_body in
  let addr = segment.Elf_interpreted_segment.elf64_segment_base in
  load_memory_segment' (bytes,addr) mem


let rec load_memory_segments segments =
  begin match segments with
    | [] -> ()
    | segment::segments' ->
      let (x,w,r) = segment.Elf_interpreted_segment.elf64_segment_flags in
      begin
        (if x
         then load_memory_segment segment prog_mem
         else load_memory_segment segment data_mem);
        load_memory_segments segments'
      end    
  end
  
let rec read_mem mem address length = 
  if length = 0  
  then []
  else
    let byte =
      try Mem.find address mem with
      | Not_found -> failwith "start address not found"
    in
    byte :: (read_mem mem (Nat_big_num.succ address) (length - 1))

let register_state_zero register_data rbn : register_value =
  let (dir,width,start_index) =
    try List.assoc rbn register_data with
    | Not_found -> failwith ("register_state_zero lookup failed (" ^ rbn)
  in register_value_zeros dir width start_index

type model = PPC | AArch64 | MIPS

let ppc_register_data_all =  [
  (*Pseudo registers*)
  ("CIA",   (D_increasing, 64, 0));
  ("NIA",   (D_increasing, 64, 0));
  ("mode64bit", (D_increasing, 1, 0));
  ("bigendianmode", (D_increasing, 1, 0));
  (* special registers *)
  ("CR",    (D_increasing, 32, 32));
  ("CTR",   (D_increasing, 64, 0 ));
  ("LR",    (D_increasing, 64, 0 ));
  ("XER",   (D_increasing, 64, 0 ));
  ("VRSAVE",(D_increasing, 32, 32));
  ("FPSCR", (D_increasing, 64, 0 ));
  ("VSCR",  (D_increasing, 32, 96));

  (* general purpose registers *)
  ("GPR0",  (D_increasing, 64, 0 ));
  ("GPR1",  (D_increasing, 64, 0 ));
  ("GPR2",  (D_increasing, 64, 0 ));
  ("GPR3",  (D_increasing, 64, 0 ));
  ("GPR4",  (D_increasing, 64, 0 ));
  ("GPR5",  (D_increasing, 64, 0 ));
  ("GPR6",  (D_increasing, 64, 0 ));
  ("GPR7",  (D_increasing, 64, 0 ));
  ("GPR8",  (D_increasing, 64, 0 ));
  ("GPR9",  (D_increasing, 64, 0 ));
  ("GPR10", (D_increasing, 64, 0 ));
  ("GPR11", (D_increasing, 64, 0 ));
  ("GPR12", (D_increasing, 64, 0 ));
  ("GPR13", (D_increasing, 64, 0 ));
  ("GPR14", (D_increasing, 64, 0 ));
  ("GPR15", (D_increasing, 64, 0 ));
  ("GPR16", (D_increasing, 64, 0 ));
  ("GPR17", (D_increasing, 64, 0 ));
  ("GPR18", (D_increasing, 64, 0 ));
  ("GPR19", (D_increasing, 64, 0 ));
  ("GPR20", (D_increasing, 64, 0 ));
  ("GPR21", (D_increasing, 64, 0 ));
  ("GPR22", (D_increasing, 64, 0 ));
  ("GPR23", (D_increasing, 64, 0 ));
  ("GPR24", (D_increasing, 64, 0 ));
  ("GPR25", (D_increasing, 64, 0 ));
  ("GPR26", (D_increasing, 64, 0 ));
  ("GPR27", (D_increasing, 64, 0 ));
  ("GPR28", (D_increasing, 64, 0 ));
  ("GPR29", (D_increasing, 64, 0 ));
  ("GPR30", (D_increasing, 64, 0 ));
  ("GPR31", (D_increasing, 64, 0 ));
  (* vector registers *)
  ("VR0",  (D_increasing, 128, 0 ));
  ("VR1",  (D_increasing, 128, 0 ));
  ("VR2",  (D_increasing, 128, 0 ));
  ("VR3",  (D_increasing, 128, 0 ));
  ("VR4",  (D_increasing, 128, 0 ));
  ("VR5",  (D_increasing, 128, 0 ));
  ("VR6",  (D_increasing, 128, 0 ));
  ("VR7",  (D_increasing, 128, 0 ));
  ("VR8",  (D_increasing, 128, 0 ));
  ("VR9",  (D_increasing, 128, 0 ));
  ("VR10", (D_increasing, 128, 0 ));
  ("VR11", (D_increasing, 128, 0 ));
  ("VR12", (D_increasing, 128, 0 ));
  ("VR13", (D_increasing, 128, 0 ));
  ("VR14", (D_increasing, 128, 0 ));
  ("VR15", (D_increasing, 128, 0 ));
  ("VR16", (D_increasing, 128, 0 ));
  ("VR17", (D_increasing, 128, 0 ));
  ("VR18", (D_increasing, 128, 0 ));
  ("VR19", (D_increasing, 128, 0 ));
  ("VR20", (D_increasing, 128, 0 ));
  ("VR21", (D_increasing, 128, 0 ));
  ("VR22", (D_increasing, 128, 0 ));
  ("VR23", (D_increasing, 128, 0 ));
  ("VR24", (D_increasing, 128, 0 ));
  ("VR25", (D_increasing, 128, 0 ));
  ("VR26", (D_increasing, 128, 0 ));
  ("VR27", (D_increasing, 128, 0 ));
  ("VR28", (D_increasing, 128, 0 ));
  ("VR29", (D_increasing, 128, 0 ));
  ("VR30", (D_increasing, 128, 0 ));
  ("VR31", (D_increasing, 128, 0 ));
  (* floating-point registers *)
  ("FPR0",  (D_increasing, 64, 0 ));
  ("FPR1",  (D_increasing, 64, 0 ));
  ("FPR2",  (D_increasing, 64, 0 ));
  ("FPR3",  (D_increasing, 64, 0 ));
  ("FPR4",  (D_increasing, 64, 0 ));
  ("FPR5",  (D_increasing, 64, 0 ));
  ("FPR6",  (D_increasing, 64, 0 ));
  ("FPR7",  (D_increasing, 64, 0 ));
  ("FPR8",  (D_increasing, 64, 0 ));
  ("FPR9",  (D_increasing, 64, 0 ));
  ("FPR10", (D_increasing, 64, 0 ));
  ("FPR11", (D_increasing, 64, 0 ));
  ("FPR12", (D_increasing, 64, 0 ));
  ("FPR13", (D_increasing, 64, 0 ));
  ("FPR14", (D_increasing, 64, 0 ));
  ("FPR15", (D_increasing, 64, 0 ));
  ("FPR16", (D_increasing, 64, 0 ));
  ("FPR17", (D_increasing, 64, 0 ));
  ("FPR18", (D_increasing, 64, 0 ));
  ("FPR19", (D_increasing, 64, 0 ));
  ("FPR20", (D_increasing, 64, 0 ));
  ("FPR21", (D_increasing, 64, 0 ));
  ("FPR22", (D_increasing, 64, 0 ));
  ("FPR23", (D_increasing, 64, 0 ));
  ("FPR24", (D_increasing, 64, 0 ));
  ("FPR25", (D_increasing, 64, 0 ));
  ("FPR26", (D_increasing, 64, 0 ));
  ("FPR27", (D_increasing, 64, 0 ));
  ("FPR28", (D_increasing, 64, 0 ));
  ("FPR29", (D_increasing, 64, 0 ));
  ("FPR30", (D_increasing, 64, 0 ));
  ("FPR31", (D_increasing, 64, 0 ));
]

let initial_stack_and_reg_data_of_PPC_elf_file e_entry all_data_memory =
  (* set up initial registers, per 3.4.1 of 64-bit PowerPC ELF Application Binary Interface Supplement 1.9 *)

  let auxiliary_vector_space = Nat_big_num.of_string "17592186042368" (*"0xffffffff800"*) in
  (* notionally there should be at least an AT_NULL auxiliary vector entry there, but our examples will never read it *)

  (* take start of stack roughly where running gdb on hello5 on bim says it is*)
  let initial_GPR1_stack_pointer = Nat_big_num.of_string "17592186040320" (*"0xffffffff000"*) in
  let initial_GPR1_stack_pointer_value =
    Interp_interface.register_value_of_integer 64 0 Interp_interface.D_increasing initial_GPR1_stack_pointer in
  (* ELF says we need an initial zero doubleword there *)
  let initial_stack_data =
    (* the code actually uses the stack, both above and below, so we map a bit more memory*)
    (* this is a fairly big but arbitrary chunk *)
    (* let initial_stack_data_address = Nat_big_num.sub initial_GPR1_stack_pointer (Nat_big_num.of_int 128) in
        [("initial_stack_data", initial_stack_data_address, Lem_list.replicate (128+32) 0 ))] in *)
    (* this is the stack memory that test 1938 actually uses *)
    [ ("initial_stack_data1", Nat_big_num.sub initial_GPR1_stack_pointer (Nat_big_num.of_int 128),
       Lem_list.replicate 8 0 );
      ("initial_stack_data2", Nat_big_num.sub initial_GPR1_stack_pointer (Nat_big_num.of_int 8),
       Lem_list.replicate 8  0 );
      ("initial_stack_data3", Nat_big_num.add initial_GPR1_stack_pointer (Nat_big_num.of_int 16),
       Lem_list.replicate 8  0 )] in
  
  (* read TOC from the second field of the function descriptor pointed to by e_entry*)
  let initial_GPR2_TOC =
    Interp_interface.register_value_of_address
      (Interp_interface.address_of_byte_list
         (List.map (fun b -> match b with Some b -> b | None -> failwith "Address had undefined")
             (List.map byte_of_byte_lifted
                (read_mem all_data_memory
                   (Nat_big_num.add (Nat_big_num.of_int 8) e_entry) 8))))
      Interp_interface.D_increasing in
  (* these initial register values are all mandated to be zero, but that's handled by the generic zeroing below
      let initial_GPR3_argc = (Nat_big_num.of_int 0) in
      let initial_GPR4_argv = (Nat_big_num.of_int 0) in
      let initial_GPR5_envp = (Nat_big_num.of_int 0) in
      let initial_FPSCR = (Nat_big_num.of_int 0) in
  *)
  let initial_register_abi_data : (string * Interp_interface.register_value) list =
    [ ("GPR1", initial_GPR1_stack_pointer_value);
      ("GPR2", initial_GPR2_TOC);
  (*
    ("GPR3", initial_GPR3_argc);
    ("GPR4", initial_GPR4_argv);
    ("GPR5", initial_GPR5_envp);
    ("FPSCR", initial_FPSCR);
    *)
    ] in

  (initial_stack_data, initial_register_abi_data)


let aarch64_reg bit_count name = (name, (D_decreasing, bit_count, bit_count - 1))

let aarch64_PC_data = [aarch64_reg 64 "_PC"]

(* most of the PSTATE fields are aliases to other registers so they
   don't appear here *)
let aarch64_PSTATE_data  = [
  aarch64_reg 1 "PSTATE_nRW";
  aarch64_reg 1 "PSTATE_E";
  aarch64_reg 5 "PSTATE_M";
]

let aarch64_general_purpose_registers_data = [
  aarch64_reg 64 "R0";
  aarch64_reg 64 "R1";
  aarch64_reg 64 "R2";
  aarch64_reg 64 "R3";
  aarch64_reg 64 "R4";
  aarch64_reg 64 "R5";
  aarch64_reg 64 "R6";
  aarch64_reg 64 "R7";
  aarch64_reg 64 "R8";
  aarch64_reg 64 "R9";
  aarch64_reg 64 "R10";
  aarch64_reg 64 "R11";
  aarch64_reg 64 "R12";
  aarch64_reg 64 "R13";
  aarch64_reg 64 "R14";
  aarch64_reg 64 "R15";
  aarch64_reg 64 "R16";
  aarch64_reg 64 "R17";
  aarch64_reg 64 "R18";
  aarch64_reg 64 "R19";
  aarch64_reg 64 "R20";
  aarch64_reg 64 "R21";
  aarch64_reg 64 "R22";
  aarch64_reg 64 "R23";
  aarch64_reg 64 "R24";
  aarch64_reg 64 "R25";
  aarch64_reg 64 "R26";
  aarch64_reg 64 "R27";
  aarch64_reg 64 "R28";
  aarch64_reg 64 "R29";
  aarch64_reg 64 "R30";
]

let aarch64_SIMD_registers_data = [
  aarch64_reg 128 "V0";
  aarch64_reg 128 "V1";
  aarch64_reg 128 "V2";
  aarch64_reg 128 "V3";
  aarch64_reg 128 "V4";
  aarch64_reg 128 "V5";
  aarch64_reg 128 "V6";
  aarch64_reg 128 "V7";
  aarch64_reg 128 "V8";
  aarch64_reg 128 "V9";
  aarch64_reg 128 "V10";
  aarch64_reg 128 "V11";
  aarch64_reg 128 "V12";
  aarch64_reg 128 "V13";
  aarch64_reg 128 "V14";
  aarch64_reg 128 "V15";
  aarch64_reg 128 "V16";
  aarch64_reg 128 "V17";
  aarch64_reg 128 "V18";
  aarch64_reg 128 "V19";
  aarch64_reg 128 "V20";
  aarch64_reg 128 "V21";
  aarch64_reg 128 "V22";
  aarch64_reg 128 "V23";
  aarch64_reg 128 "V24";
  aarch64_reg 128 "V25";
  aarch64_reg 128 "V26";
  aarch64_reg 128 "V27";
  aarch64_reg 128 "V28";
  aarch64_reg 128 "V29";
  aarch64_reg 128 "V30";
  aarch64_reg 128 "V31";
]

let aarch64_special_purpose_registers_data = [
  aarch64_reg 32 "CurrentEL";
  aarch64_reg 32 "DAIF";
  aarch64_reg 32 "NZCV";
  aarch64_reg 64 "SP_EL0";
  aarch64_reg 64 "SP_EL1";
  aarch64_reg 64 "SP_EL2";
  aarch64_reg 64 "SP_EL3";
  aarch64_reg 32 "SPSel";
  aarch64_reg 32 "SPSR_EL1";
  aarch64_reg 32 "SPSR_EL2";
  aarch64_reg 32 "SPSR_EL3";
  aarch64_reg 64 "ELR_EL1";
  aarch64_reg 64 "ELR_EL2";
  aarch64_reg 64 "ELR_EL3";
]

let aarch64_general_system_control_registers_data = [
  aarch64_reg 64 "HCR_EL2";
  aarch64_reg 64 "ID_AA64MMFR0_EL1";
  aarch64_reg 64 "RVBAR_EL1";
  aarch64_reg 64 "RVBAR_EL2";
  aarch64_reg 64 "RVBAR_EL3";
  aarch64_reg 32 "SCR_EL3";
  aarch64_reg 32 "SCTLR_EL1";
  aarch64_reg 32 "SCTLR_EL2";
  aarch64_reg 32 "SCTLR_EL3";
  aarch64_reg 64 "TCR_EL1";
  aarch64_reg 32 "TCR_EL2";
  aarch64_reg 32 "TCR_EL3";
]

let aarch64_debug_registers_data = [
  aarch64_reg 32 "DBGPRCR_EL1";
  aarch64_reg 32 "OSDLR_EL1";
]

let aarch64_performance_monitors_registers_data = []
let aarch64_generic_timer_registers_data = []
let aarch64_generic_interrupt_controller_CPU_interface_registers_data = []

let aarch64_external_debug_registers_data = [
  aarch64_reg 32 "EDSCR";
]

let aarch32_general_system_control_registers_data = [
  aarch64_reg 32 "SCR";
]

let aarch32_debug_registers_data = [
  aarch64_reg 32 "DBGOSDLR";
  aarch64_reg 32 "DBGPRCR";
]

let aarch64_register_data_all =
  aarch64_PC_data @
  aarch64_PSTATE_data @
  aarch64_general_purpose_registers_data @
  aarch64_SIMD_registers_data @
  aarch64_special_purpose_registers_data @
  aarch64_general_system_control_registers_data @
  aarch64_debug_registers_data @
  aarch64_performance_monitors_registers_data @
  aarch64_generic_timer_registers_data @
  aarch64_generic_interrupt_controller_CPU_interface_registers_data @
  aarch64_external_debug_registers_data @
  aarch32_general_system_control_registers_data @
  aarch32_debug_registers_data

let initial_stack_and_reg_data_of_AAarch64_elf_file e_entry all_data_memory =
  let (reg_SP_EL0_direction, reg_SP_EL0_width, reg_SP_EL0_initial_index) =
    List.assoc "SP_EL0" aarch64_register_data_all in
  
  (* we compiled a small program that prints out SP and run it a few
      times on the Nexus9, these are the results:
      0x0000007fe7f903e0
      0x0000007fdcdbf3f0
      0x0000007fcbe1ba90
      0x0000007fcf378280
      0x0000007fdd54b8d0
      0x0000007fd961bc10
      0x0000007ff3be6350
      0x0000007fd6bf6ef0
      0x0000007fff7676f0
      0x0000007ff2c34560 *)
  let initial_SP_EL0 = Nat_big_num.of_string "549739036672" (*"0x0000007fff000000"*) in
  let initial_SP_EL0_value =
    Interp_interface.register_value_of_integer
      reg_SP_EL0_width
      reg_SP_EL0_initial_index
      reg_SP_EL0_direction
      initial_SP_EL0
  in

  (* ELF says we need an initial zero doubleword there *)
  (* the code actually uses the stack, both above and below, so we map a bit more memory*)
  let initial_stack_data =
    (* this is a fairly big but arbitrary chunk: *)
    (* let initial_stack_data_address = Nat_big_num.sub initial_GPR1_stack_pointer (Nat_big_num.of_int 128) in
        [("initial_stack_data", initial_stack_data_address, Lem_list.replicate (128+32) 0 ))] in *)
    
    [ ("initial_stack_data1", Nat_big_num.sub initial_SP_EL0 (Nat_big_num.of_int 16),  Lem_list.replicate 8 0);
      ("initial_stack_data2", Nat_big_num.sub initial_SP_EL0 (Nat_big_num.of_int 8),   Lem_list.replicate 8 0)
    ]
  in

  let initial_register_abi_data : (string * Interp_interface.register_value) list =
    [("SP_EL0", initial_SP_EL0_value)]
  in

  (initial_stack_data, initial_register_abi_data)

let initial_reg_file reg_data init =
  List.iter (fun (reg_name, _) -> reg := Reg.add reg_name (init reg_name) !reg) reg_data

let initial_system_state_of_elf_file name = 

  (* call ELF analyser on file *)
  match Sail_interface.populate_and_obtain_global_symbol_init_info name with
  | Error.Fail s -> failwith ("populate_and_obtain_global_symbol_init_info: " ^ s)
  | Error.Success 
      ((elf_epi: Sail_interface.executable_process_image),
       (symbol_map: Elf_file.global_symbol_init_info))
    ->
    let (segments, e_entry, e_machine) =
      begin match elf_epi with
        | ELF_Class_32 _ -> failwith "cannot handle ELF_Class_32"
        | ELF_Class_64 (segments,e_entry,e_machine) ->
          (* remove all the auto generated segments (they contain only 0s) *)
          let segments =
            Lem_list.mapMaybe
              (fun (seg, prov) -> if prov = Elf_file.FromELF then Some seg else None)
              segments
          in
          (segments,e_entry,e_machine)
      end
    in

    (* construct program memory and start address *)
    begin
      prog_mem := Mem.empty;
      data_mem := Mem.empty;
      load_memory_segments segments;

      let (isa_defs, isa_memory_access, isa_externs, isa_model, model_reg_d, startaddr,
           initial_stack_data, initial_register_abi_data, register_data_all) =
        match Nat_big_num.to_int e_machine with
        | 21  (* EM_PPC64 *) ->
          let startaddr =
            let e_entry = Uint64.of_int64 (Nat_big_num.to_int64 e_entry) in
            match Abi_power64.abi_power64_compute_program_entry_point segments e_entry with
            | Error.Fail s -> failwith "Failed computing entry point"
            | Error.Success s -> Nat_big_num.of_int64 (Uint64.to_int64 s)
          in
          let (initial_stack_data, initial_register_abi_data) =
            initial_stack_and_reg_data_of_PPC_elf_file e_entry !data_mem in

            (Power.defs,
             (Power_extras.read_memory_functions,Power_extras.memory_writes,[],[],Power_extras.barrier_functions),
             Power_extras.power_externs,
             PPC,
             D_increasing,
             startaddr,
             initial_stack_data,
             initial_register_abi_data,
             ppc_register_data_all)

        | 183 (* EM_AARCH64 *) ->
          let startaddr =
            let e_entry = Uint64.of_int64 (Nat_big_num.to_int64 e_entry) in
            match Abi_aarch64_le.abi_aarch64_le_compute_program_entry_point segments e_entry with
            | Error.Fail s -> failwith "Failed computing entry point"
            | Error.Success s -> Nat_big_num.of_int64 (Uint64.to_int64 s)
          in
          
          let (initial_stack_data, initial_register_abi_data) =
            initial_stack_and_reg_data_of_AAarch64_elf_file e_entry !data_mem in
          
          (ArmV8.defs,
           (ArmV8_extras.aArch64_read_memory_functions,
            ArmV8_extras.aArch64_memory_writes,
	    ArmV8_extras.aArch64_memory_eas,
	    ArmV8_extras.aArch64_memory_vals,
            ArmV8_extras.aArch64_barrier_functions),
           [],
           AArch64,
           D_decreasing,
           startaddr,
           initial_stack_data,
           initial_register_abi_data,
           aarch64_register_data_all)

        | _ -> failwith (Printf.sprintf "Sail sequential interpreter can't handle the e_machine value %s, only EM_PPC64 and EM_AARCH64 are supported." (Nat_big_num.to_string e_machine))
      in
      
      (* pull the object symbols from the symbol table *)
      let symbol_table : (string * Nat_big_num.num * int * word8 list (*their bytes*)) list =
        let rec convert_symbol_table symbol_map =
          begin match symbol_map with
          | [] -> []
          | ((name: string),
             ((typ: Nat_big_num.num),
              (size: Nat_big_num.num (*number of bytes*)),
              (address: Nat_big_num.num),
              (mb: Byte_sequence.byte_sequence option (*present iff type=stt_object*)),
              (binding: Nat_big_num.num)))
	    (*              (mb: Byte_sequence_wrapper.t option (*present iff type=stt_object*)) )) *)
            ::symbol_map' ->
            if Nat_big_num.equal typ Elf_symbol_table.stt_object && not (Nat_big_num.equal size (Nat_big_num.of_int 0))
            then
              (
                (* an object symbol - map *)
                (*Printf.printf "*** size %d ***\n" (Nat_big_num.to_int size);*)
                let bytes =
                  (match mb with
                   | None -> raise (Failure "this cannot happen")
                   | Some (Sequence bytes) ->
                     List.map (fun (c:char) -> Char.code c) bytes) in
                 (name, address, List.length bytes, bytes):: convert_symbol_table symbol_map'
              )
              else
                (* not an object symbol or of zero size - ignore *)
                convert_symbol_table symbol_map'
          end
        in
        (List.map (fun (n,a,bs) -> (n,a,List.length bs,bs)) initial_stack_data) @ convert_symbol_table symbol_map
      in

      (* invert the symbol table to use for pp *)
      let symbol_table_pp : ((Interp_interface.address * int) * string) list =
        (* map symbol to (bindings, footprint),
           if a symbol appears more then onece keep the one with higher
           precedence (stb_global > stb_weak > stb_local) *)
        let map =
          List.fold_left
            (fun map (name, (typ, size, address, mb, binding)) ->
               if String.length name <> 0 &&
                  (if String.length name = 1 then Char.code (String.get name 0) <> 0 else true) &&
                  not (Nat_big_num.equal address (Nat_big_num.of_int 0))
               then
                 try
                   let (binding', _) = StringMap.find name map in
                   if  Nat_big_num.equal binding' Elf_symbol_table.stb_local ||
                       Nat_big_num.equal binding Elf_symbol_table.stb_global
                   then
                     StringMap.add name (binding,
                                         (Interp_interface.address_of_integer address, Nat_big_num.to_int size)) map
                   else map
                 with Not_found ->
                   StringMap.add name (binding,
                                       (Interp_interface.address_of_integer address, Nat_big_num.to_int size)) map
                     
               else map
            )
            StringMap.empty
            symbol_map
        in

        List.map (fun (name, (binding, fp)) -> (fp, name)) (StringMap.bindings map)
      in


      (* Now we examine the rest of the data memory,
         removing the footprint of the symbols and chunking it into aligned chunks *)
      
      let rec remove_symbols_from_data_memory data_mem symbols =
        match symbols with
        | [] -> data_mem
        | (name,address,size,bs)::symbols' ->
          let data_mem' =
            Mem.filter
              (fun a v ->
                 not (Nat_big_num.greater_equal a address &&
                      Nat_big_num.less a (Nat_big_num.add (Nat_big_num.of_int (List.length bs)) address)))
              data_mem in
          remove_symbols_from_data_memory data_mem' symbols' in

      let trimmed_data_memory : (Nat_big_num.num * memory_byte) list =
        Mem.bindings (remove_symbols_from_data_memory !data_mem symbol_table) in

      (* make sure that's ordered increasingly.... *)
      let trimmed_data_memory =
        List.sort (fun (a,b) (a',b') -> Nat_big_num.compare a a') trimmed_data_memory in

      let aligned a n =  (* a mod n = 0 *)
        let n_big = Nat_big_num.of_int n in
        Nat_big_num.equal (Nat_big_num.modulus a n_big) ((Nat_big_num.of_int 0)) in

      let isplus a' a n =   (* a' = a+n *)
        Nat_big_num.equal a' (Nat_big_num.add (Nat_big_num.of_int n) a) in

      let rec chunk_data_memory dm =
        match dm with
        | (a0,b0)::(a1,b1)::(a2,b2)::(a3,b3)::(a4,b4)::(a5,b5)::(a6,b6)::(a7,b7)::dm'  when
            (aligned a0 8 && isplus a1 a0 1 && isplus a2 a0 2 && isplus a3 a0 3 &&
             isplus a4 a0 4 && isplus a5 a0 5 && isplus a6 a0 6 && isplus a7 a0 7) ->
          (a0,8,[b0;b1;b2;b3;b4;b5;b6;b7]) :: chunk_data_memory dm'
        | (a0,b0)::(a1,b1)::(a2,b2)::(a3,b3)::dm' when
            (aligned a0 4 && isplus a1 a0 1 && isplus a2 a0 2 && isplus a3 a0 3) ->
              (a0,4,[b0;b1;b2;b3]) :: chunk_data_memory dm'
        | (a0,b0)::(a1,b1)::dm' when
            (aligned a0 2 && isplus a1 a0 1) ->
              (a0,2,[b0;b1]) :: chunk_data_memory dm'
        | (a0,b0)::dm' ->
            (a0,1,[b0]):: chunk_data_memory dm'
        | [] -> [] in

      let initial_register_state =
        fun rbn ->
          try
            List.assoc rbn initial_register_abi_data
          with
            Not_found ->
              (register_state_zero register_data_all) rbn
      in

      begin
        (initial_reg_file register_data_all initial_register_state);
        
        (* construct initial system state *)
        let initial_system_state =
          (isa_defs,
	   isa_memory_access,
	   isa_externs,
           isa_model,
           model_reg_d,
           startaddr,
           (Interp_interface.address_of_integer startaddr))
        in
        
        (initial_system_state, symbol_table_pp)
      end
    end

let eager_eval = ref true

let args = [
  ("--file", Arg.Set_string file, "filename binary code to load in memory");
  ("--quiet", Arg.Clear Run_interp_model.debug, "do not display interpreter actions");
  ("--interactive", Arg.Clear eager_eval , "interactive execution");
]

let time_it action arg =
  let start_time = Sys.time () in
  ignore (action arg);
  let finish_time = Sys.time () in
  finish_time -. start_time

let stop_condition_met model instr =
  match model with
  | PPC ->
    (match instr with
     | ("Sc", [("Lev", _, arg)], []) ->
       Nat_big_num.equal (integer_of_bit_list arg) (Nat_big_num.of_int 32)
     | _ -> false)
  | AArch64 -> (match instr with
    | ("ImplementationDefinedStopFetching", _, _) -> true
    | _ -> false)
  | MIPS -> false

let is_branch model instruction =
  let (name,_,_) = instruction in
  match (model , name) with
  | (PPC, "B") -> true
  | (PPC, "Bc") -> true
  | (PPC, "Bclr") -> true
  | (PPC, "Bcctr") -> true
  | (PPC, _) -> false
  | (AArch64, "BranchImmediate") -> true
  | (AArch64, "BranchConditional") -> true
  | (AArch64, "CompareAndBranch") -> true
  | (AArch64, "TestBitAndBranch") -> true
  | (AArch64, "BranchRegister") -> true
  | (AArch64, _) -> false
  | (MIPS,_) -> false (*todo,fill this in*)

let set_next_instruction_address model =
  match model with
  | PPC ->
    let cia = Reg.find "CIA" !reg in
    let cia_addr = address_of_register_value cia in
    (match cia_addr with
    | Some cia_addr ->
      let nia_addr = add_address_nat cia_addr 4 in 
      let nia = register_value_of_address nia_addr Interp_interface.D_increasing in
      reg := Reg.add "NIA" nia !reg
    | _ -> failwith "CIA address contains unknown or undefined")
  | AArch64 ->
    let pc = Reg.find "_PC" !reg in
    let pc_addr = address_of_register_value pc in
    (match pc_addr with
     | Some pc_addr ->
       let n_addr = add_address_nat pc_addr 4 in
       let n_pc = register_value_of_address n_addr D_decreasing in
       reg := Reg.add "_PC" n_pc !reg
     | _ -> failwith "_PC address contains unknown or undefined")
  | MIPS -> ()

let add1 = Nat_big_num.add (Nat_big_num.of_int 1)

let fetch_instruction_opcode_and_update_ia model =
  match model with
  | PPC ->
    let cia = Reg.find "CIA" !reg in
    let cia_addr = address_of_register_value cia in
    (match cia_addr with
     | Some cia_addr ->
       let cia_a = integer_of_address cia_addr in
       let opcode = List.map (fun b -> match b with
           | Some b -> b
           | None -> failwith "A byte in opcode contained unknown or undef")
           (List.map byte_of_memory_byte
              [Mem.find cia_a !prog_mem;
               Mem.find (add1 cia_a) !prog_mem;
               Mem.find (add1 (add1 cia_a)) !prog_mem;
               Mem.find (add1 (add1 (add1 cia_a))) !prog_mem]) in
       begin
         reg := Reg.add "CIA" (Reg.find "NIA" !reg) !reg;
         Opcode opcode
       end
     | None -> failwith "CIA address contains unknown or undefined")
  | AArch64 ->
    let pc = Reg.find "_PC" !reg in
    let pc_addr = address_of_register_value pc in
    (match pc_addr with
     | Some pc_addr ->
       let pc_a = integer_of_address pc_addr in
       let opcode =  List.map (fun b -> match b with
           | Some b -> b
           | None -> failwith "A byte in opcode contained unknown or undef")
           (List.map byte_of_memory_byte
              ([Mem.find pc_a !prog_mem;
                Mem.find (add1 pc_a) !prog_mem;
                Mem.find (add1 (add1 pc_a)) !prog_mem;
                Mem.find (add1 (add1 (add1 pc_a))) !prog_mem])) in
       Opcode opcode       
     | None -> failwith "_PC address contains unknown or undefined")
  | _ -> assert false
                 
    

let rec fde_loop count context model mode track_dependencies opcode =
  debugf "\n**** instruction %d  ****\n" count;
  let (instruction,istate) = match Interp_inter_imp.decode_to_istate context opcode with
    | Instr(instruction,istate) ->
      debugf "\n**** Running: %s ****\n" (Printing_functions.instruction_to_string instruction);
      (instruction,istate)
    | Decode_error d ->
      (match d with
       | Interp_interface.Unsupported_instruction_error instr ->
         debugf "\n**** Encountered unsupported instruction %s ****\n" (Printing_functions.instruction_to_string instr)
       | Interp_interface.Not_an_instruction_error op ->
         debugf "\n**** Encountered non-decodeable opcode ****\n"
       | Internal_error s -> debugf "\n**** Internal error on decode: %s ****\n" s);
      exit 1
  in
  if stop_condition_met model instruction
  then eprintf "\nSUCCESS program terminated\n"
  else
    begin
      set_next_instruction_address model;
      match Run_interp_model.run  istate !reg !data_mem !eager_eval track_dependencies mode "execute" with
      | false, _,_, _ -> eprintf "FAILURE\n"; exit 1
      | true, mode, track_dependencies, (my_reg, my_mem) ->
        reg := my_reg;
        data_mem := my_mem;
        let opcode = fetch_instruction_opcode_and_update_ia model in
          fde_loop (count + 1) context model (Some mode) (ref track_dependencies) opcode
    end

let run () =
  Arg.parse args (fun _ -> raise (Arg.Bad "anonymous parameter")) "" ;
  if !file = "" then begin
    Arg.usage args "";
    exit 1;
  end;
  if !eager_eval then Run_interp_model.debug := true;

  let ((isa_defs,
       (isa_m0, isa_m1, isa_m2, isa_m3,isa_m4),
        isa_externs,
        isa_model,
        model_reg_d,
        startaddr,
        startaddr_internal), pp_symbol_map) = initial_system_state_of_elf_file !file in

  let initial_opcode = Opcode (List.map (fun b -> match b with
      | Some b -> b
      | None -> failwith "A byte in opcode contained unknown or undef")
      (List.map byte_of_memory_byte
         [Mem.find startaddr !prog_mem;
          Mem.find (add1 startaddr) !prog_mem;
          Mem.find (add1 (add1 startaddr)) !prog_mem;
          Mem.find (add1 (add1 (add1 startaddr))) !prog_mem])) in
  let context = build_context isa_defs isa_m0 isa_m1 isa_m2 isa_m3 isa_m4 isa_externs in
  reg := Reg.add "PC" (register_value_of_address startaddr_internal model_reg_d ) !reg;
  
  (* entry point: unit -> unit fde *)
  let name = Filename.basename !file in
  let t =time_it (fun () -> fde_loop 0 context isa_model (Some Run) (ref false) initial_opcode) () in
  eprintf "Execution time for file %s: %f seconds\n" name t

run () ;;
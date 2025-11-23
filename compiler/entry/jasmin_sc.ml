open Jasmin
open Jasmin_checksafety
open Jasmin_sc
open Cmdliner
open CommonCLI
open Utils
open Prog

module type ArchCoreWithAnalyze = sig
  module C : Arch_full.Core_arch
  val analyze :
    Wsize.wsize ->
    (C.reg, C.regx, C.xreg, C.rflag, C.cond, C.asm_op, C.extra_op) Arch_extra.extended_op Sopn.asmOp ->
    (unit, (C.reg, C.regx, C.xreg, C.rflag, C.cond, C.asm_op, C.extra_op) Arch_extra.extended_op) func ->
    (unit, (C.reg, C.regx, C.xreg, C.rflag, C.cond, C.asm_op, C.extra_op) Arch_extra.extended_op) func ->
    (unit, (C.reg, C.regx, C.xreg, C.rflag, C.cond, C.asm_op, C.extra_op) Arch_extra.extended_op) prog ->
    bool
end

let check_safety_p _pd _asmOp analyze (p : (_, 'asm) Prog.prog) source_p =
  let () = SafetyConfig.pp_current_config_diff () in

  let is_safe =
    List.fold_left (fun res f_decl ->
        if FInfo.is_export f_decl.f_cc then
          let () = Format.eprintf "@[<v>Analyzing function %s@]@."
              f_decl.f_name.fn_name in

          let source_f_decl = List.find (fun source_f_decl ->
              f_decl.f_name.fn_name = source_f_decl.f_name.fn_name
            ) (snd source_p) in
          analyze source_f_decl f_decl p && res
        else res)
      true
      (List.rev (snd p)) in
  if not is_safe then exit(2)

let parse_and_preprocess (type reg regx xreg rflag cond asm_op extra_op)
  (module Arch : Arch_full.Arch
    with type reg = reg
     and type regx = regx
     and type xreg = xreg
     and type rflag = rflag
     and type cond = cond
     and type asm_op = asm_op
     and type extra_op = extra_op) file idirs =
  let _env, pprog, _ast =
    try Compile.parse_file Arch.arch_info ~idirs file with
    | Annot.AnnotationError (loc, code) -> hierror ~loc:(Lone loc) ~kind:"annotation error" "%t" code
    | Pretyping.TyError (loc, code) -> hierror ~loc:(Lone loc) ~kind:"typing error" "%a" Pretyping.pp_tyerror code
    | Syntax.ParseError (loc, msg) -> hierror ~loc:(Lone loc) ~kind:"parse error" "%s" (Option.default "" msg)
  in

  let prog =
    try Compile.preprocess Arch.reg_size Arch.asmOp pprog
    with Typing.TyError (loc, code) ->
      hierror ~loc:(Lmore loc) ~kind:"typing error" "%s" code
(* in
  let prog =
    if !slice <> []
      then Slicing.slice !slice prog
    else prog
*)
  in
  prog

let parse_and_safetycheck arch call_conv idirs debug _functions file=
  Glob_options.debug := debug;
  let (module P : ArchCoreWithAnalyze) =
      match arch with
      | X86_64 ->
         (module struct
            module C = (val CoreArchFactory.core_arch_x86 ~use_lea:!Glob_options.lea ~use_set0:!Glob_options.set0 call_conv)
            let analyze = X86_safety.analyze
          end)
      | ARM_M4 ->
         (module struct
            module C = CoreArchFactory.Core_arch_ARM
            let analyze _ _ _ _ _ = failwith "TODO_ARM: analyze"
          end)
      | RISCV ->
         (module struct
            module C = CoreArchFactory.Core_arch_RISCV
            let analyze _ _ _ _ _ = failwith "TODO_RISCV: analyze"
          end)
  in
  let module A = Arch_full.Arch_from_Core_arch (P.C) in

  let prog = parse_and_preprocess (module A) file idirs in
  let source_prog = prog in

  (*  This passes will be added when analyse will be ready *)

  let prog = Compile.do_wint_int (module A) source_prog in

  let prog = Compile.create_safety_asserts (module A) prog in

  check_safety_p
    A.pointer_data
    A.asmOp
    (P.analyze A.pointer_data A.asmOp)
    prog
    source_prog
  |> fun () -> exit 0


let functions =
  let doc =
    "Only safety check the given function (and its dependencies). This argument may \
     be extract to check many functions. If not given, all functions will be \
     safety checked."
  in
  Arg.(value & opt_all string [] & info [ "f"; "function" ] ~doc)

let debug =
  let doc = "Print debug information" in
  Arg.(value & flag & info [ "debug" ] ~doc)

let file =
  let doc = "The Jasmin source file to safety check" in
  Arg.(required & pos 0 (some non_dir_file) None & info [] ~docv:"JAZZ" ~doc)

let () =
  let doc = "Safety Checking of Jasmin program" in
  let man =
    [
      `S Manpage.s_environment;
      Manpage.s_environment_intro;
      `I ("OCAMLRUNPARAM", "This is an OCaml program");
      `I ("JASMINPATH", "To resolve $(i,require) directives");
    ]
  in
  let info =
    Cmd.info "jasmin-sc" ~version:Glob_options.version_string ~doc ~man
  in
  Cmd.v info
    Term.(const parse_and_safetycheck $ arch $ call_conv $ idirs $ debug $ functions $ file)
  |> Cmd.eval |> exit

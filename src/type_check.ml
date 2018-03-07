(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Util
open Ast_util
module Big_int = Nat_big_num

(* opt_tc_debug controls the verbosity of the type checker. 0 is
   silent, 1 prints a tree of the type derivation and 2 is like 1 but
   with much more debug information. *)
let opt_tc_debug = ref 0

(* opt_no_effects turns of the effect checking. This can break
   re-writer passes, so it should only be used for debugging. *)
let opt_no_effects = ref false

let depth = ref 0

let rec indent n = match n with
  | 0 -> ""
  | n -> "|   " ^ indent (n - 1)

let typ_debug m = if !opt_tc_debug > 1 then prerr_endline (indent !depth ^ m) else ()

let typ_print m = if !opt_tc_debug > 0 then prerr_endline (indent !depth ^ m) else ()

type type_error =
  (* First parameter is the error that caused us to start doing type
     coercions, the second is the errors encountered by all possible
     coercions *)
  | Err_no_casts of unit exp * type_error * type_error list
  | Err_no_overloading of id * (id * type_error) list
  | Err_unresolved_quants of id * typquant * quant_item list * Parse_ast.l KBindings.t * n_constraint list
  | Err_subtype of typ * typ * n_constraint list
  | Err_no_num_ident of id
  | Err_other of string

let assign_colors xs =
  List.mapi (fun n x -> (fun str -> termcode (n mod 5 + 91) ^ str), x) xs

let pp_quantifier color l kid =
  PPrint.string ("Quantifier " ^ (string_of_kid kid |> color |> Util.clear) ^ " from " ^ Reporting_basic.loc_to_string ~padding:"\n" ~color:color l)

let pp_type_error err =
  let open PPrint in
  let rec pp_err = function
    | Err_no_casts (exp, trigger, []) ->
       (string "Tried performing type coercion on" ^//^ Pretty_print_sail.doc_exp exp)
       ^^ hardline ^^ (string "Failed because" ^//^ pp_err trigger)
    | Err_no_casts (exp, trigger, errs) ->
       (string "Tried performing type coercion on" ^//^ Pretty_print_sail.doc_exp exp)
       ^/^ string "Failed because" ^//^ pp_err trigger
    | Err_no_overloading (id, errs) ->
       string ("No overloadings for " ^ string_of_id id ^ ", tried:") ^//^
         group (separate_map hardline (fun (id, err) -> string (string_of_id id) ^^ colon ^//^ pp_err err) errs)
    | Err_subtype (typ1, typ2, []) ->
       separate space [ string (string_of_typ typ1);
                        string "is not a subtype of";
                        string (string_of_typ typ2) ]
    | Err_subtype (typ1, typ2, constrs) ->
       separate space [ string (string_of_typ typ1);
                        string "is not a subtype of";
                        string (string_of_typ typ2) ]
       ^/^ string "in context"
       ^//^ string (string_of_list ", " string_of_n_constraint constrs)
    | Err_no_num_ident id ->
       string "No num identifier" ^^ space ^^ string (string_of_id id)
    | Err_unresolved_quants (id, typq, quants, typ_vars, all_constraints) ->
       let add_nc_qi = function
         | QI_aux (QI_const nc, _) -> nc_and nc
         | _ -> (fun x -> x)
       in
       let nc = List.fold_left (fun nc qi -> add_nc_qi qi nc) nc_true quants in
       let relevant_typ_vars = KBindings.filter (fun kid _ -> KidSet.mem kid (tyvars_of_nc nc)) typ_vars |> KBindings.bindings |> assign_colors in
       let colors = List.fold_left (fun colors (color, (kid, _)) -> KBindings.add kid color colors) KBindings.empty relevant_typ_vars in
       let relevant_constraints = List.filter (fun nc' -> not (KidSet.is_empty (KidSet.inter (tyvars_of_nc nc) (tyvars_of_nc nc')))) all_constraints in
       (string "Could not resolve quantifiers when calling " ^^ string (string_of_id id) ^^ space ^^ colon ^^ space ^^ string (string_of_typquant typq)
       ^//^ group (separate_map hardline (fun quant -> string (string_of_quant_item ~colors:colors quant)) quants))
       ^^ twice hardline
       ^^ separate_map (twice hardline) (fun (color, (kid, l)) -> pp_quantifier color l kid) relevant_typ_vars
       ^^ twice hardline
       ^^ (string "Relevant constraints include"
           ^//^ group (separate_map hardline (fun nc -> string (string_of_n_constraint ~colors:colors nc)) relevant_constraints))
       ^^ hardline
    | Err_other str -> string str
  in
  pp_err err

let rec string_of_type_error err =
  let open PPrint in
  let b = Buffer.create 20 in
  ToBuffer.pretty 1. 120 b (pp_type_error err);
  "\n" ^ Buffer.contents b

exception Type_error of l * type_error;;

let typ_error l m = raise (Type_error (l, Err_other m))

let typ_raise l err = raise (Type_error (l, err))

let deinfix = function
  | Id_aux (Id v, l) -> Id_aux (DeIid v, l)
  | Id_aux (DeIid v, l) -> Id_aux (DeIid v, l)

let field_name rec_id id =
  match rec_id, id with
  | Id_aux (Id r, _), Id_aux (Id v, l) -> Id_aux (Id (r ^ "." ^ v), l)
  | _, _ -> assert false

let string_of_bind (typquant, typ) = string_of_typquant typquant ^ ". " ^ string_of_typ typ

let orig_kid (Kid_aux (Var v, l) as kid) =
  try
    let i = String.rindex v '#' in
    Kid_aux (Var ("'" ^ String.sub v (i + 1) (String.length v - i - 1)), l)
  with
  | Not_found -> kid

let destruct_list (Typ_aux (typ_aux, _)) =
  match typ_aux with
  | Typ_app (f, [Typ_arg_aux (Typ_arg_typ typ, _)])
       when string_of_id f = "list" -> Some typ
  | _ -> None

let is_atom (Typ_aux (typ_aux, _)) =
  match typ_aux with
  | Typ_app (f, [_]) when string_of_id f = "atom" -> true
  | _ -> false

(**************************************************************************)
(* 1. Substitutions                                                       *)
(**************************************************************************)

let rec nexp_subst sv subst (Nexp_aux (nexp, l)) = Nexp_aux (nexp_subst_aux sv subst nexp, l)
and nexp_subst_aux sv subst = function
  | Nexp_id v -> Nexp_id v
  | Nexp_var kid -> if Kid.compare kid sv = 0 then subst else Nexp_var kid
  | Nexp_constant c -> Nexp_constant c
  | Nexp_times (nexp1, nexp2) -> Nexp_times (nexp_subst sv subst nexp1, nexp_subst sv subst nexp2)
  | Nexp_sum (nexp1, nexp2) -> Nexp_sum (nexp_subst sv subst nexp1, nexp_subst sv subst nexp2)
  | Nexp_minus (nexp1, nexp2) -> Nexp_minus (nexp_subst sv subst nexp1, nexp_subst sv subst nexp2)
  | Nexp_app (id, nexps) -> Nexp_app (id, List.map (nexp_subst sv subst) nexps)
  | Nexp_exp nexp -> Nexp_exp (nexp_subst sv subst nexp)
  | Nexp_neg nexp -> Nexp_neg (nexp_subst sv subst nexp)

let rec nexp_set_to_or l subst = function
  | [] -> typ_error l "Cannot substitute into empty nexp set"
  | [int] -> NC_equal (subst, nconstant int)
  | (int :: ints) -> NC_or (mk_nc (NC_equal (subst, nconstant int)), mk_nc (nexp_set_to_or l subst ints))

let rec nc_subst_nexp sv subst (NC_aux (nc, l)) = NC_aux (nc_subst_nexp_aux l sv subst nc, l)
and nc_subst_nexp_aux l sv subst = function
  | NC_equal (n1, n2) -> NC_equal (nexp_subst sv subst n1, nexp_subst sv subst n2)
  | NC_bounded_ge (n1, n2) -> NC_bounded_ge (nexp_subst sv subst n1, nexp_subst sv subst n2)
  | NC_bounded_le (n1, n2) -> NC_bounded_le (nexp_subst sv subst n1, nexp_subst sv subst n2)
  | NC_not_equal (n1, n2) -> NC_not_equal (nexp_subst sv subst n1, nexp_subst sv subst n2)
  | NC_set (kid, ints) as set_nc ->
     if Kid.compare kid sv = 0
     then nexp_set_to_or l (mk_nexp subst) ints
     else set_nc
  | NC_or (nc1, nc2) -> NC_or (nc_subst_nexp sv subst nc1, nc_subst_nexp sv subst nc2)
  | NC_and (nc1, nc2) -> NC_and (nc_subst_nexp sv subst nc1, nc_subst_nexp sv subst nc2)
  | NC_false -> NC_false
  | NC_true -> NC_true

let rec typ_subst_nexp sv subst (Typ_aux (typ, l)) = Typ_aux (typ_subst_nexp_aux sv subst typ, l)
and typ_subst_nexp_aux sv subst = function
  | Typ_id v -> Typ_id v
  | Typ_var kid -> Typ_var kid
  | Typ_fn (typ1, typ2, effs) -> Typ_fn (typ_subst_nexp sv subst typ1, typ_subst_nexp sv subst typ2, effs)
  | Typ_tup typs -> Typ_tup (List.map (typ_subst_nexp sv subst) typs)
  | Typ_app (f, args) -> Typ_app (f, List.map (typ_subst_arg_nexp sv subst) args)
  | Typ_exist (kids, nc, typ) when KidSet.mem sv (KidSet.of_list kids) -> Typ_exist (kids, nc, typ)
  | Typ_exist (kids, nc, typ) -> Typ_exist (kids, nc_subst_nexp sv subst nc, typ_subst_nexp sv subst typ)
and typ_subst_arg_nexp sv subst (Typ_arg_aux (arg, l)) = Typ_arg_aux (typ_subst_arg_nexp_aux sv subst arg, l)
and typ_subst_arg_nexp_aux sv subst = function
  | Typ_arg_nexp nexp -> Typ_arg_nexp (nexp_subst sv subst nexp)
  | Typ_arg_typ typ -> Typ_arg_typ (typ_subst_nexp sv subst typ)
  | Typ_arg_order ord -> Typ_arg_order ord

let rec typ_subst_typ sv subst (Typ_aux (typ, l)) = Typ_aux (typ_subst_typ_aux sv subst typ, l)
and typ_subst_typ_aux sv subst = function
  | Typ_id v -> Typ_id v
  | Typ_var kid -> if Kid.compare kid sv = 0 then subst else Typ_var kid
  | Typ_fn (typ1, typ2, effs) -> Typ_fn (typ_subst_typ sv subst typ1, typ_subst_typ sv subst typ2, effs)
  | Typ_tup typs -> Typ_tup (List.map (typ_subst_typ sv subst) typs)
  | Typ_app (f, args) -> Typ_app (f, List.map (typ_subst_arg_typ sv subst) args)
  | Typ_exist (kids, nc, typ) -> Typ_exist (kids, nc, typ_subst_typ sv subst typ)
and typ_subst_arg_typ sv subst (Typ_arg_aux (arg, l)) = Typ_arg_aux (typ_subst_arg_typ_aux sv subst arg, l)
and typ_subst_arg_typ_aux sv subst = function
  | Typ_arg_nexp nexp -> Typ_arg_nexp nexp
  | Typ_arg_typ typ -> Typ_arg_typ (typ_subst_typ sv subst typ)
  | Typ_arg_order ord -> Typ_arg_order ord

let order_subst_aux sv subst = function
  | Ord_var kid -> if Kid.compare kid sv = 0 then subst else Ord_var kid
  | Ord_inc -> Ord_inc
  | Ord_dec -> Ord_dec

let order_subst sv subst (Ord_aux (ord, l)) = Ord_aux (order_subst_aux sv subst ord, l)

let rec typ_subst_order sv subst (Typ_aux (typ, l)) = Typ_aux (typ_subst_order_aux sv subst typ, l)
and typ_subst_order_aux sv subst = function
  | Typ_id v -> Typ_id v
  | Typ_var kid -> Typ_var kid
  | Typ_fn (typ1, typ2, effs) -> Typ_fn (typ_subst_order sv subst typ1, typ_subst_order sv subst typ2, effs)
  | Typ_tup typs -> Typ_tup (List.map (typ_subst_order sv subst) typs)
  | Typ_app (f, args) -> Typ_app (f, List.map (typ_subst_arg_order sv subst) args)
  | Typ_exist (kids, nc, typ) -> Typ_exist (kids, nc, typ_subst_order sv subst typ)
and typ_subst_arg_order sv subst (Typ_arg_aux (arg, l)) = Typ_arg_aux (typ_subst_arg_order_aux sv subst arg, l)
and typ_subst_arg_order_aux sv subst = function
  | Typ_arg_nexp nexp -> Typ_arg_nexp nexp
  | Typ_arg_typ typ -> Typ_arg_typ (typ_subst_order sv subst typ)
  | Typ_arg_order ord -> Typ_arg_order (order_subst sv subst ord)

let rec typ_subst_kid sv subst (Typ_aux (typ, l)) = Typ_aux (typ_subst_kid_aux sv subst typ, l)
and typ_subst_kid_aux sv subst = function
  | Typ_id v -> Typ_id v
  | Typ_var kid -> if Kid.compare kid sv = 0 then Typ_var subst else Typ_var kid
  | Typ_fn (typ1, typ2, effs) -> Typ_fn (typ_subst_kid sv subst typ1, typ_subst_kid sv subst typ2, effs)
  | Typ_tup typs -> Typ_tup (List.map (typ_subst_kid sv subst) typs)
  | Typ_app (f, args) -> Typ_app (f, List.map (typ_subst_arg_kid sv subst) args)
  | Typ_exist (kids, nc, typ) when KidSet.mem sv (KidSet.of_list kids) -> Typ_exist (kids, nc, typ)
  | Typ_exist (kids, nc, typ) -> Typ_exist (kids, nc_subst_nexp sv (Nexp_var subst) nc, typ_subst_kid sv subst typ)
and typ_subst_arg_kid sv subst (Typ_arg_aux (arg, l)) = Typ_arg_aux (typ_subst_arg_kid_aux sv subst arg, l)
and typ_subst_arg_kid_aux sv subst = function
  | Typ_arg_nexp nexp -> Typ_arg_nexp (nexp_subst sv (Nexp_var subst) nexp)
  | Typ_arg_typ typ -> Typ_arg_typ (typ_subst_kid sv subst typ)
  | Typ_arg_order ord -> Typ_arg_order (order_subst sv (Ord_var subst) ord)

let quant_item_subst_kid_aux sv subst = function
  | QI_id (KOpt_aux (KOpt_none kid, l)) as qid ->
     if Kid.compare kid sv = 0 then QI_id (KOpt_aux (KOpt_none subst, l)) else qid
  | QI_id (KOpt_aux (KOpt_kind (k, kid), l)) as qid ->
     if Kid.compare kid sv = 0 then QI_id (KOpt_aux (KOpt_kind (k, subst), l)) else qid
  | QI_const nc -> QI_const (nc_subst_nexp sv (Nexp_var subst) nc)

let quant_item_subst_kid sv subst (QI_aux (quant, l)) = QI_aux (quant_item_subst_kid_aux sv subst quant, l)

let typquant_subst_kid_aux sv subst = function
  | TypQ_tq quants -> TypQ_tq (List.map (quant_item_subst_kid sv subst) quants)
  | TypQ_no_forall -> TypQ_no_forall

let typquant_subst_kid sv subst (TypQ_aux (typq, l)) = TypQ_aux (typquant_subst_kid_aux sv subst typq, l)

(**************************************************************************)
(* 2. Environment                                                         *)
(**************************************************************************)

let ex_counter = ref 0

let fresh_existential ?name:(n="") () =
  let fresh = Kid_aux (Var ("'ex" ^ string_of_int !ex_counter ^ "#" ^ n), Parse_ast.Unknown) in
  incr ex_counter; fresh

(** Flatten existential removes double nested existentials, and pulls
   existentials out of tuples. It is used when canonicalising
   types. **)
let rec flatten_existential (Typ_aux (typ_aux, l)) = Typ_aux (flatten_existential_aux l typ_aux, l)
and flatten_existential_aux l = function
  | Typ_exist (kids1, nc1, Typ_aux (Typ_exist (kids2, nc2, typ), _)) ->
     Typ_exist (kids1 @ kids2, nc_and nc1 nc2, typ)
  | Typ_tup typs ->
     let typs = List.map flatten_existential typs in
     let collect_existential (kidset, ncs, typs) (Typ_aux (typ_aux, l) as typ) =
       match typ_aux with
       | Typ_exist (kids, nc, typ) ->
          if KidSet.is_empty (KidSet.inter kidset (KidSet.of_list kids)) then
            (KidSet.union kidset (KidSet.of_list kids), nc :: ncs, typ :: typs)
          else
            let fresh_kids = List.map (fun kid -> (kid, fresh_existential ~name:(string_of_id (id_of_kid kid)) ())) kids in
            let nc = List.fold_left (fun nc (kid, fresh) -> nc_subst_nexp kid (Nexp_var fresh) nc) nc fresh_kids in
            let typ = List.fold_left (fun typ (kid, fresh) -> typ_subst_nexp kid (Nexp_var fresh) typ) typ fresh_kids in
            (KidSet.union kidset (KidSet.of_list (List.map snd fresh_kids)), nc :: ncs, typ :: typs)
       | _ -> (kidset, ncs, typ :: typs)
     in
     let kidset, ncs, typs = List.fold_left collect_existential (KidSet.empty, [], []) (List.rev typs) in
     if KidSet.is_empty kidset then
       Typ_tup typs
     else
       Typ_exist (KidSet.elements kidset, List.fold_left nc_and (List.hd ncs) (List.tl ncs), Typ_aux (Typ_tup typs, l))
  | typ_aux -> typ_aux

module Env : sig
  type t
  val add_val_spec : id -> typquant * typ -> t -> t
  val update_val_spec : id -> typquant * typ -> t -> t
  val define_val_spec : id -> t -> t
  val get_val_spec : id -> t -> typquant * typ
  val is_union_constructor : id -> t -> bool
  val add_record : id -> typquant -> (typ * id) list -> t -> t
  val is_record : id -> t -> bool
  val get_accessor_fn : id -> id -> t -> typquant * typ
  val get_accessor : id -> id -> t -> typquant * typ * typ * effect
  val add_local : id -> mut * typ -> t -> t
  val get_locals : t -> (mut * typ) Bindings.t
  val add_variant : id -> typquant * type_union list -> t -> t
  val add_union_id : id -> typquant * typ -> t -> t
  val add_flow : id -> (typ -> typ) -> t -> t
  val get_flow : id -> t -> typ -> typ
  val is_register : id -> t -> bool
  val get_register : id -> t -> typ
  val add_register : id -> typ -> t -> t
  val is_mutable : id -> t -> bool
  val get_constraints : t -> n_constraint list
  val add_constraint : n_constraint -> t -> t
  val get_typ_var : kid -> t -> base_kind_aux
  val get_typ_vars : t -> base_kind_aux KBindings.t
  val get_typ_var_locs : t -> Parse_ast.l KBindings.t
  val add_typ_var : Parse_ast.l -> kid -> base_kind_aux -> t -> t
  val get_ret_typ : t -> typ option
  val add_ret_typ : typ -> t -> t
  val add_typ_synonym : id -> (t -> typ_arg list -> typ) -> t -> t
  val get_typ_synonym : id -> t -> t -> typ_arg list -> typ
  val add_num_def : id -> nexp -> t -> t
  val get_num_def : id -> t -> nexp
  val add_overloads : id -> id list -> t -> t
  val get_overloads : id -> t -> id list
  val is_extern : id -> t -> string -> bool
  val add_extern : id -> (string -> string option) -> t -> t
  val get_extern : id -> t -> string -> string
  val get_default_order : t -> order
  val set_default_order_inc : t -> t
  val set_default_order_dec : t -> t
  val add_enum : id -> id list -> t -> t
  val get_enum : id -> t -> id list
  val get_casts : t -> id list
  val allow_casts : t -> bool
  val no_casts : t -> t
  val enable_casts : t -> t
  val add_cast : id -> t -> t
  val allow_polymorphic_undefineds : t -> t
  val polymorphic_undefineds : t -> bool
  val lookup_id : id -> t -> lvar
  val fresh_kid : ?kid:kid -> t -> kid
  val expand_synonyms : t -> typ -> typ
  val canonicalize : t -> typ -> typ
  val is_canonical : t -> typ -> bool
  val base_typ_of : t -> typ -> typ
  val add_smt_op : id -> string -> t -> t
  val get_smt_op : id -> t -> string
  val have_smt_op : id -> t -> bool
  (* Well formedness-checks *)
  val wf_typ : ?exs:KidSet.t -> t -> typ -> unit
  val wf_constraint : ?exs:KidSet.t -> t -> n_constraint -> unit

  (* Some of the code in the environment needs to use the Z3 prover,
     which is defined below. To break the circularity this would cause
     (as the prove code depends on the environment), we add a
     reference to the prover to the initial environment. *)
  val add_prover : (t -> n_constraint -> bool) -> t -> t

  (* This must not be exported, initial_env sets up a correct initial
     environment. *)
  val empty : t

  val pattern_completeness_ctx : t -> Pattern_completeness.ctx
end = struct
  type t =
    { top_val_specs : (typquant * typ) Bindings.t;
      defined_val_specs : IdSet.t;
      locals : (mut * typ) Bindings.t;
      union_ids : (typquant * typ) Bindings.t;
      registers : typ Bindings.t;
      variants : (typquant * type_union list) Bindings.t;
      typ_vars : (base_kind_aux * Parse_ast.l) KBindings.t;
      typ_synonyms : (t -> typ_arg list -> typ) Bindings.t;
      num_defs : nexp Bindings.t;
      overloads : (id list) Bindings.t;
      flow : (typ -> typ) Bindings.t;
      enums : IdSet.t Bindings.t;
      records : (typquant * (typ * id) list) Bindings.t;
      accessors : (typquant * typ) Bindings.t;
      externs : (string -> string option) Bindings.t;
      smt_ops : string Bindings.t;
      casts : id list;
      allow_casts : bool;
      constraints : n_constraint list;
      default_order : order option;
      ret_typ : typ option;
      poly_undefineds : bool;
      prove : t -> n_constraint -> bool;
    }

  let empty =
    { top_val_specs = Bindings.empty;
      defined_val_specs = IdSet.empty;
      locals = Bindings.empty;
      union_ids = Bindings.empty;
      registers = Bindings.empty;
      variants = Bindings.empty;
      typ_vars = KBindings.empty;
      typ_synonyms = Bindings.empty;
      num_defs = Bindings.empty;
      overloads = Bindings.empty;
      flow = Bindings.empty;
      enums = Bindings.empty;
      records = Bindings.empty;
      accessors = Bindings.empty;
      externs = Bindings.empty;
      smt_ops = Bindings.empty;
      casts = [];
      allow_casts = true;
      constraints = [];
      default_order = None;
      ret_typ = None;
      poly_undefineds = false;
      prove = (fun _ _ -> false);
    }

  let add_prover f env = { env with prove = f }

  let get_typ_var kid env =
    try fst (KBindings.find kid env.typ_vars) with
    | Not_found -> typ_error (kid_loc kid) ("No kind identifier " ^ string_of_kid kid)

  let get_typ_vars env = KBindings.map fst (env.typ_vars)
  let get_typ_var_locs env = KBindings.map snd (env.typ_vars)

  let bk_counter = ref 0
  let bk_name () = let kid = mk_kid ("bk#" ^ string_of_int !bk_counter) in incr bk_counter; kid

  let kinds_typq kinds = mk_typquant (List.map (fun k -> mk_qi_id k (bk_name ())) kinds)

  let builtin_typs =
    List.fold_left (fun m (name, kinds) -> Bindings.add (mk_id name) (kinds_typq kinds) m) Bindings.empty
      [ ("atom", [BK_nat]);
        ("vector", [BK_nat; BK_order; BK_type]);
        ("register", [BK_type]);
        ("ref", [BK_type]);
        ("bit", []);
        ("unit", []);
        ("int", []);
        ("bool", []);
        ("real", []);
        ("list", [BK_type]);
        ("string", []);
        ("itself", [BK_nat])
      ]

  let bound_typ_id env id =
    Bindings.mem id env.typ_synonyms
    || Bindings.mem id env.variants
    || Bindings.mem id env.records
    || Bindings.mem id env.enums
    || Bindings.mem id builtin_typs

  let get_overloads id env =
    try Bindings.find id env.overloads with
    | Not_found -> []

  let add_overloads id ids env =
    typ_print ("Adding overloads for " ^ string_of_id id ^ " [" ^ string_of_list ", " string_of_id ids ^ "]" |> Util.gray |> Util.clear);
    let existing = try Bindings.find id env.overloads with Not_found -> [] in
    { env with overloads = Bindings.add id (existing @ ids) env.overloads }

  let add_smt_op id str env =
    typ_print ("Adding smt binding " ^ string_of_id id ^ " to " ^ str);
    { env with smt_ops = Bindings.add id str env.smt_ops }

  let get_smt_op (Id_aux (_, l) as id) env =
    let rec first_smt_op = function
      | id :: ids -> (try Bindings.find id env.smt_ops with Not_found -> first_smt_op ids)
      | [] -> typ_error l ("No SMT op for " ^ string_of_id id)
    in
    try Bindings.find id env.smt_ops with
    | Not_found -> first_smt_op (get_overloads id env)

  let have_smt_op id env =
    try ignore(get_smt_op id env); true with Type_error _ -> false

  let rec infer_kind env id =
    if Bindings.mem id builtin_typs then
      Bindings.find id builtin_typs
    else if Bindings.mem id env.variants then
      fst (Bindings.find id env.variants)
    else if Bindings.mem id env.records then
      fst (Bindings.find id env.records)
    else if Bindings.mem id env.enums then
      mk_typquant []
    else if Bindings.mem id env.typ_synonyms then
      typ_error (id_loc id) ("Cannot infer kind of type synonym " ^ string_of_id id)
    else
      typ_error (id_loc id) ("Cannot infer kind of " ^  string_of_id id)

  let check_args_typquant id env args typq =
    let kopts, ncs = quant_split typq in
    let rec subst_args kopts args =
      match kopts, args with
      | kopt :: kopts, Typ_arg_aux (Typ_arg_nexp arg, _) :: args when is_nat_kopt kopt ->
         List.map (nc_subst_nexp (kopt_kid kopt) (unaux_nexp arg)) (subst_args kopts args)
      | kopt :: kopts, Typ_arg_aux (Typ_arg_typ arg, _) :: args when is_typ_kopt kopt ->
         subst_args kopts args
      | kopt :: kopts, Typ_arg_aux (Typ_arg_order arg, _) :: args when is_order_kopt kopt ->
         subst_args kopts args
      | [], [] -> ncs
      | _, Typ_arg_aux (_, l) :: _ -> typ_error l ("Error when processing type quantifer arguments " ^ string_of_typquant typq)
      | _, _ -> typ_error Parse_ast.Unknown ("Error when processing type quantifer arguments " ^ string_of_typquant typq)
    in
    let ncs = subst_args kopts args in
    if List.for_all (env.prove env) ncs
    then ()
    else typ_error (id_loc id) ("Could not prove " ^ string_of_list ", " string_of_n_constraint ncs ^ " for type constructor " ^ string_of_id id)

  let rec expand_synonyms env (Typ_aux (typ, l) as t) =
    match typ with
    | Typ_tup typs -> Typ_aux (Typ_tup (List.map (expand_synonyms env) typs), l)
    | Typ_fn (typ1, typ2, effs) -> Typ_aux (Typ_fn (expand_synonyms env typ1, expand_synonyms env typ2, effs), l)
    | Typ_app (id, args) ->
       begin
         try
           let synonym = Bindings.find id env.typ_synonyms in
           expand_synonyms env (synonym env args)
         with
       | Not_found -> Typ_aux (Typ_app (id, List.map (expand_synonyms_arg env) args), l)
       end
    | Typ_id id ->
       begin
         try
           let synonym = Bindings.find id env.typ_synonyms in
           expand_synonyms env (synonym env [])
         with
         | Not_found -> Typ_aux (Typ_id id, l)
       end
    | Typ_exist (kids, nc, typ) ->
       (* When expanding an existential synonym we need to take care
          to add the type variables and constraints to the
          environment, so we can check constraints attached to type
          synonyms within the existential. Furthermore, we must take
          care to avoid clobbering any existing type variables in
          scope while doing this. *)
       let rebindings = ref [] in

       let rename_kid kid = if KBindings.mem kid env.typ_vars then prepend_kid "syn#" kid else kid in
       let add_typ_var env kid =
         if KBindings.mem kid env.typ_vars then
           (rebindings := kid :: !rebindings; { env with typ_vars = KBindings.add (prepend_kid "syn#" kid) (BK_nat, l) env.typ_vars })
         else
           { env with typ_vars = KBindings.add kid (BK_nat, l) env.typ_vars }
       in

       let env = List.fold_left add_typ_var env kids in
       let kids = List.map rename_kid kids in
       let nc = List.fold_left (fun nc kid -> nc_subst_nexp kid (Nexp_var (prepend_kid "syn#" kid)) nc) nc !rebindings in
       let typ = List.fold_left (fun typ kid -> typ_subst_nexp kid (Nexp_var (prepend_kid "syn#" kid)) typ) typ !rebindings in
       typ_debug ("Synonym existential: {" ^ string_of_list " " string_of_kid kids ^ ", " ^ string_of_n_constraint nc ^ ". " ^ string_of_typ typ ^ "}");
       let env = { env with constraints = nc :: env.constraints } in
       Typ_aux (Typ_exist (kids, nc, expand_synonyms env typ), l)
    | Typ_var v -> Typ_aux (Typ_var v, l)
  and expand_synonyms_arg env (Typ_arg_aux (typ_arg, l)) =
    match typ_arg with
    | Typ_arg_typ typ -> Typ_arg_aux (Typ_arg_typ (expand_synonyms env typ), l)
    | arg -> Typ_arg_aux (arg, l)

  (** Map over all nexps in a type - excluding those in existential constraints **)
  let rec map_nexps f (Typ_aux (typ_aux, l) as typ) =
    match typ_aux with
    | Typ_id _ | Typ_var _ -> typ
    | Typ_fn (arg_typ, ret_typ, effect) -> Typ_aux (Typ_fn (map_nexps f arg_typ, map_nexps f ret_typ, effect), l)
    | Typ_tup typs -> Typ_aux (Typ_tup (List.map (map_nexps f) typs), l)
    | Typ_exist (kids, nc, typ) -> Typ_aux (Typ_exist (kids, nc, map_nexps f typ), l)
    | Typ_app (id, args) -> Typ_aux (Typ_app (id, List.map (map_nexps_arg f) args), l)
  and map_nexps_arg f (Typ_arg_aux (arg_aux, l) as arg) =
    match arg_aux with
    | Typ_arg_order _ | Typ_arg_typ _ -> arg
    | Typ_arg_nexp n -> Typ_arg_aux (Typ_arg_nexp (f n), l)

  let canonical env typ =
    let typ = flatten_existential (expand_synonyms env typ) in
    let counter = ref 0 in
    let complex_nexps = ref KBindings.empty in
    let simplify_nexp (Nexp_aux (nexp_aux, l) as nexp) =
      match nexp_aux with
      | Nexp_var _ | Nexp_constant _ -> nexp
      | _ ->
         let kid = Kid_aux (Var ("'c#" ^ string_of_int !counter), l) in
         complex_nexps := KBindings.add kid nexp !complex_nexps;
         incr counter;
         Nexp_aux (Nexp_var kid, l)
    in
    let typ = map_nexps simplify_nexp typ in
    let existentials = KBindings.bindings !complex_nexps |> List.map fst in
    let constrs = List.fold_left (fun ncs (kid, nexp) -> nc_eq (nvar kid) nexp :: ncs) [] (KBindings.bindings !complex_nexps) in
    existentials, constrs, typ

  let is_canonical env typ =
    let typ = expand_synonyms env typ in
    let counter = ref 0 in
    let simplify_nexp (Nexp_aux (nexp_aux, l) as nexp) =
      match nexp_aux with
      | Nexp_var _ | Nexp_constant _ -> nexp
      | _ -> (incr counter; nexp)
    in
    let typ = map_nexps simplify_nexp typ in
    not (!counter > 0)

  let rec canonicalize env typ =
    match typ with
    | Typ_aux (Typ_fn (arg_typ, ret_typ, effects), l) when is_canonical env arg_typ ->
       Typ_aux (Typ_fn (arg_typ, canonicalize env ret_typ, effects), l)
    | Typ_aux (Typ_fn _, l) -> typ_error l ("Function type " ^ string_of_typ typ ^ " is not canonical")
    | _ ->
       let existentials, constrs, (Typ_aux (typ_aux, l) as typ) = canonical env typ in
       if existentials = [] then
         typ
       else
         let typ_aux = match typ_aux with
           | Typ_tup _ | Typ_app _ -> Typ_exist (existentials, List.fold_left nc_and (List.hd constrs) (List.tl constrs), typ)
           | Typ_exist (kids, nc, typ) -> Typ_exist (kids @ existentials, List.fold_left nc_and nc constrs, typ)
           | Typ_fn _ | Typ_id _ | Typ_var _ -> assert false (* These must be simple *)
         in
         Typ_aux (typ_aux, l)

  (* Check if a type, order, n-expression or constraint is
     well-formed. Throws a type error if the type is badly formed. *)
  let rec wf_typ ?exs:(exs=KidSet.empty) env typ =
    typ_debug ("Well-formed " ^ string_of_typ typ);
    let (Typ_aux (typ_aux, l)) = canonicalize env typ in
    match typ_aux with
    | Typ_id id when bound_typ_id env id ->
       let typq = infer_kind env id in
       if quant_kopts typq != []
       then typ_error l ("Type constructor " ^ string_of_id id ^ " expected " ^ string_of_typquant typq)
       else ()
    | Typ_id id -> typ_error l ("Undefined type " ^ string_of_id id)
    | Typ_var kid when KBindings.mem kid env.typ_vars -> ()
    | Typ_var kid -> typ_error l ("Unbound kind identifier " ^ string_of_kid kid ^ " in type " ^ string_of_typ typ)
    | Typ_fn (typ_arg, typ_ret, effs) -> wf_typ ~exs:exs env typ_arg; wf_typ ~exs:exs env typ_ret
    | Typ_tup typs -> List.iter (wf_typ ~exs:exs env) typs
    | Typ_app (id, args) when bound_typ_id env id ->
       List.iter (wf_typ_arg ~exs:exs env) args;
       check_args_typquant id env args (infer_kind env id)
    | Typ_app (id, _) -> typ_error l ("Undefined type " ^ string_of_id id)
    | Typ_exist ([], _, _) -> typ_error l ("Existential must have some type variables")
    | Typ_exist (kids, nc, typ) when KidSet.is_empty exs ->
       wf_constraint ~exs:(KidSet.of_list kids) env nc;
       wf_typ ~exs:(KidSet.of_list kids) { env with constraints = nc :: env.constraints } typ
    | Typ_exist (_, _, _) -> typ_error l ("Nested existentials are not allowed")
  and wf_typ_arg ?exs:(exs=KidSet.empty) env (Typ_arg_aux (typ_arg_aux, _)) =
    match typ_arg_aux with
    | Typ_arg_nexp nexp -> wf_nexp ~exs:exs env nexp
    | Typ_arg_typ typ -> wf_typ ~exs:exs env typ
    | Typ_arg_order ord -> wf_order env ord
  and wf_nexp ?exs:(exs=KidSet.empty) env (Nexp_aux (nexp_aux, l)) =
    match nexp_aux with
    | Nexp_id _ -> ()
    | Nexp_var kid when KidSet.mem kid exs -> ()
    | Nexp_var kid ->
       begin
         match get_typ_var kid env with
         | BK_nat -> ()
         | kind -> typ_error l ("Constraint is badly formed, "
                                ^ string_of_kid kid ^ " has kind "
                                ^ string_of_base_kind_aux kind ^ " but should have kind Nat")
       end
    | Nexp_constant _ -> ()
    | Nexp_app (id, nexps) ->
       let _ = get_smt_op id env in
       List.iter (fun n -> wf_nexp ~exs:exs env n) nexps
    | Nexp_times (nexp1, nexp2) -> wf_nexp ~exs:exs env nexp1; wf_nexp ~exs:exs env nexp2
    | Nexp_sum (nexp1, nexp2) -> wf_nexp ~exs:exs env nexp1; wf_nexp ~exs:exs env nexp2
    | Nexp_minus (nexp1, nexp2) -> wf_nexp ~exs:exs env nexp1; wf_nexp ~exs:exs env nexp2
    | Nexp_exp nexp -> wf_nexp ~exs:exs env nexp (* MAYBE: Could put restrictions on what is allowed here *)
    | Nexp_neg nexp -> wf_nexp ~exs:exs env nexp
  and wf_order env (Ord_aux (ord_aux, l)) =
    match ord_aux with
    | Ord_var kid ->
       begin
         match get_typ_var kid env with
         | BK_order -> ()
         | kind -> typ_error l ("Order is badly formed, "
                                ^ string_of_kid kid ^ " has kind "
                                ^ string_of_base_kind_aux kind ^ " but should have kind Order")
       end
    | Ord_inc | Ord_dec -> ()
  and wf_constraint ?exs:(exs=KidSet.empty) env (NC_aux (nc, _)) =
    match nc with
    | NC_equal (n1, n2) -> wf_nexp ~exs:exs env n1; wf_nexp ~exs:exs env n2
    | NC_not_equal (n1, n2) -> wf_nexp ~exs:exs env n1; wf_nexp ~exs:exs env n2
    | NC_bounded_ge (n1, n2) -> wf_nexp ~exs:exs env n1; wf_nexp ~exs:exs env n2
    | NC_bounded_le (n1, n2) -> wf_nexp ~exs:exs env n1; wf_nexp ~exs:exs env n2
    | NC_set (kid, ints) -> () (* MAYBE: We could demand that ints are all unique here *)
    | NC_or (nc1, nc2) -> wf_constraint ~exs:exs env nc1; wf_constraint ~exs:exs env nc2
    | NC_and (nc1, nc2) -> wf_constraint ~exs:exs env nc1; wf_constraint ~exs:exs env nc2
    | NC_true | NC_false -> ()

  let counter = ref 0

  let fresh_kid ?kid:(kid=mk_kid "") env =
    let suffix = if Kid.compare kid (mk_kid "") = 0 then "#" else "#" ^ string_of_id (id_of_kid kid) in
    let fresh = Kid_aux (Var ("'fv" ^ string_of_int !counter ^ suffix), Parse_ast.Unknown) in
    incr counter; fresh

  let freshen_kid env kid (typq, typ) =
    let fresh = fresh_kid ~kid:kid env in
    if KidSet.mem kid (KidSet.of_list (List.map kopt_kid (quant_kopts typq))) then
      (typquant_subst_kid kid fresh typq, typ_subst_kid kid fresh typ)
    else
      (typq, typ)

  let freshen_bind env bind =
    List.fold_left (fun bind (kid, _) -> freshen_kid env kid bind) bind (KBindings.bindings env.typ_vars)

  let get_val_spec id env =
    try
      let bind = Bindings.find id env.top_val_specs in
      typ_debug ("get_val_spec: Env has " ^ string_of_list ", " (fun (kid, bk) -> string_of_kid kid ^ " => " ^ string_of_base_kind_aux (fst bk)) (KBindings.bindings env.typ_vars));
      let bind' = List.fold_left (fun bind (kid, _) -> freshen_kid env kid bind) bind (KBindings.bindings env.typ_vars) in
      typ_debug ("get_val_spec: freshened to " ^ string_of_bind bind');
      bind'
    with
    | Not_found -> typ_error (id_loc id) ("No val spec found for " ^ string_of_id id)

  let update_val_spec id (typq, typ) env =
    begin
      let typ = expand_synonyms env typ in
      typ_print (("Adding val spec binding " |> Util.gray |> Util.clear) ^ string_of_id id ^ " :: " ^ string_of_bind (typq, typ));
      { env with top_val_specs = Bindings.add id (typq, canonicalize env typ) env.top_val_specs }
    end

  let add_val_spec id bind env =
    if Bindings.mem id env.top_val_specs
    then typ_error (id_loc id) ("Identifier " ^ string_of_id id ^ " is already bound")
    else update_val_spec id bind env

  let define_val_spec id env =
    if IdSet.mem id env.defined_val_specs
    then typ_error (id_loc id) ("Function " ^ string_of_id id ^ " has already been declared")
    else { env with defined_val_specs = IdSet.add id env.defined_val_specs }

  let is_union_constructor id env =
    let is_ctor id (Tu_aux (tu, _)) = match tu with
      | Tu_ty_id (_, ctor_id) when Id.compare id ctor_id = 0 -> true
      | _ -> false
    in
    let type_unions = List.concat (List.map (fun (_, (_, tus)) -> tus) (Bindings.bindings env.variants)) in
    List.exists (is_ctor id) type_unions

  let add_enum id ids env =
    if bound_typ_id env id
    then typ_error (id_loc id) ("Cannot create enum " ^ string_of_id id ^ ", type name is already bound")
    else
      begin
        typ_print (("Adding enum " |> Util.gray |> Util.clear) ^ string_of_id id);
        { env with enums = Bindings.add id (IdSet.of_list ids) env.enums }
      end

  let get_enum id env =
    try IdSet.elements (Bindings.find id env.enums)
    with
    | Not_found -> typ_error (id_loc id) ("Enumeration " ^ string_of_id id ^ " does not exist")

  let is_record id env = Bindings.mem id env.records

  let add_record id typq fields env =
    if bound_typ_id env id
    then typ_error (id_loc id) ("Cannot create record " ^ string_of_id id ^ ", type name is already bound")
    else
      begin
        typ_print ("Adding record " ^ string_of_id id);
        let rec record_typ_args = function
          | [] -> []
          | ((QI_aux (QI_id kopt, _)) :: qis) when is_nat_kopt kopt ->
             mk_typ_arg (Typ_arg_nexp (nvar (kopt_kid kopt))) :: record_typ_args qis
          | ((QI_aux (QI_id kopt, _)) :: qis) when is_typ_kopt kopt ->
             mk_typ_arg (Typ_arg_typ (mk_typ (Typ_var (kopt_kid kopt)))) :: record_typ_args qis
          | ((QI_aux (QI_id kopt, _)) :: qis) when is_order_kopt kopt ->
             mk_typ_arg (Typ_arg_order (mk_ord (Ord_var (kopt_kid kopt)))) :: record_typ_args qis
          | (_ :: qis) -> record_typ_args qis
        in
        let rectyp = match record_typ_args (quant_items typq) with
          | [] -> mk_id_typ id
          | args -> mk_typ (Typ_app (id, args))
        in
        let fold_accessors accs (typ, fid) =
          let acc_typ = mk_typ (Typ_fn (rectyp, typ, Effect_aux (Effect_set [], Parse_ast.Unknown))) in
          typ_print (indent 1 ^ "Adding accessor " ^ string_of_id id ^ "." ^ string_of_id fid ^ " :: " ^ string_of_bind (typq, acc_typ));
          Bindings.add (field_name id fid) (typq, acc_typ) accs
        in
        { env with records = Bindings.add id (typq, fields) env.records;
                   accessors = List.fold_left fold_accessors env.accessors fields }
      end

  let get_accessor_fn rec_id id env =
    let freshen_bind bind = List.fold_left (fun bind (kid, _) -> freshen_kid env kid bind) bind (KBindings.bindings env.typ_vars) in
    try freshen_bind (Bindings.find (field_name rec_id id) env.accessors)
    with
    | Not_found -> typ_error (id_loc id) ("No accessor found for " ^ string_of_id (field_name rec_id id))

  let get_accessor rec_id id env =
    match get_accessor_fn rec_id id env with
    | (typq, Typ_aux (Typ_fn (rec_typ, field_typ, effect), _)) ->
       (typq, rec_typ, field_typ, effect)
    | _ -> typ_error (id_loc id) ("Accessor with non-function type found for " ^ string_of_id (field_name rec_id id))

  let is_mutable id env =
    try
      let (mut, _) = Bindings.find id env.locals in
      match mut with
      | Mutable -> true
      | Immutable -> false
    with
    | Not_found -> false

  let string_of_mtyp (mut, typ) = match mut with
    | Immutable -> string_of_typ typ
    | Mutable -> "mutable " ^ string_of_typ typ

  let add_local id mtyp env =
    begin
      wf_typ env (snd mtyp);
      if Bindings.mem id env.top_val_specs then
        typ_error (id_loc id) ("Local variable " ^ string_of_id id ^ " is already bound as a function name")
      else ();
      typ_print ("Adding local binding " ^ string_of_id id ^ " :: " ^ string_of_mtyp mtyp |> Util.gray |> Util.clear);
      { env with locals = Bindings.add id mtyp env.locals }
    end

  let add_variant id variant env =
    begin
      typ_print ("Adding variant " ^ string_of_id id);
      { env with variants = Bindings.add id variant env.variants }
    end

  let add_union_id id bind env =
    begin
      typ_print ("Adding union identifier binding " ^ string_of_id id ^ " :: " ^ string_of_bind bind);
      { env with union_ids = Bindings.add id bind env.union_ids }
    end

  let get_flow id env =
    try Bindings.find id env.flow with
    | Not_found -> fun typ -> typ

  let add_flow id f env =
    begin
      typ_print ("Adding flow constraints for " ^ string_of_id id);
      { env with flow = Bindings.add id (fun typ -> f (get_flow id env typ)) env.flow }
    end

  let is_register id env =
    Bindings.mem id env.registers

  let get_register id env =
    try Bindings.find id env.registers with
    | Not_found -> typ_error (id_loc id) ("No register binding found for " ^ string_of_id id)

  let is_extern id env backend =
    try not (Bindings.find id env.externs backend = None) with
    | Not_found -> false
    (* Bindings.mem id env.externs *)

  let add_extern id ext env =
    { env with externs = Bindings.add id ext env.externs }

  let get_extern id env backend =
    try
      match Bindings.find id env.externs backend with
      | Some ext -> ext
      | None -> typ_error (id_loc id) ("No extern binding found for " ^ string_of_id id)
    with
    | Not_found -> typ_error (id_loc id) ("No extern binding found for " ^ string_of_id id)

  let get_casts env = env.casts

  let add_register id typ env =
    wf_typ env typ;
    if Bindings.mem id env.registers
    then typ_error (id_loc id) ("Register " ^ string_of_id id ^ " is already bound")
    else
      begin
        typ_print (("Adding register binding " |> Util.gray |> Util.clear) ^ string_of_id id ^ " :: " ^ string_of_typ typ);
        { env with registers = Bindings.add id (canonicalize env typ) env.registers }
      end

  let get_locals env = env.locals

  let lookup_id id env =
    try
      let (mut, typ) = Bindings.find id env.locals in
      let flow = get_flow id env in
      Local (mut, flow typ)
    with
    | Not_found ->
       begin
         try Register (Bindings.find id env.registers) with
         | Not_found ->
            begin
              try
                let (enum, _) = List.find (fun (enum, ctors) -> IdSet.mem id ctors) (Bindings.bindings env.enums) in
                Enum (mk_typ (Typ_id enum))
              with
              | Not_found -> Unbound
            end
       end

  let add_typ_var l kid k env =
    if KBindings.mem kid env.typ_vars
    then typ_error (kid_loc kid) ("Kind identifier " ^ string_of_kid kid ^ " is already bound")
    else
      begin
        typ_print ("Adding kind identifier " ^ string_of_kid kid ^ " : " ^ string_of_base_kind_aux k |> Util.gray |> Util.clear);
        { env with typ_vars = KBindings.add kid (k, l) env.typ_vars }
      end

  let add_num_def id nexp env =
    if Bindings.mem id env.num_defs
    then typ_error (id_loc id) ("Num identifier " ^ string_of_id id ^ " is already bound")
    else
      begin
        typ_print ("Adding Num identifier " ^ string_of_id id ^ " :: " ^ string_of_nexp nexp);
        { env with num_defs = Bindings.add id nexp env.num_defs }
      end

  let get_num_def id env =
    try Bindings.find id env.num_defs with
    | Not_found -> typ_raise (id_loc id) (Err_no_num_ident id)

  let get_constraints env = env.constraints

  let add_constraint (NC_aux (_, l) as constr) env =
    wf_constraint env constr;
    begin
      typ_print ("Adding constraint " ^ string_of_n_constraint constr |> Util.gray |> Util.clear);
      { env with constraints = constr :: env.constraints }
    end

  let get_ret_typ env = env.ret_typ

  let add_ret_typ typ env = { env with ret_typ = Some typ }

  let allow_casts env = env.allow_casts

  let no_casts env = { env with allow_casts = false }
  let enable_casts env = { env with allow_casts = true }

  let add_cast cast env =
    typ_print ("Adding cast " ^ string_of_id cast);
    { env with casts = cast :: env.casts }

  let add_typ_synonym id synonym env =
    if Bindings.mem id env.typ_synonyms
    then typ_error (id_loc id) ("Type synonym " ^ string_of_id id ^ " already exists")
    else
      begin
        typ_print (("Adding type synonym " |> Util.gray |> Util.clear) ^ string_of_id id);
        { env with typ_synonyms = Bindings.add id synonym env.typ_synonyms }
      end

  let get_typ_synonym id env = Bindings.find id env.typ_synonyms

  let get_default_order env =
    match env.default_order with
    | None -> typ_error Parse_ast.Unknown ("No default order has been set")
    | Some ord -> ord

  let set_default_order o env =
    match env.default_order with
    | None -> { env with default_order = Some (Ord_aux (o, Parse_ast.Unknown)) }
    | Some _ -> typ_error Parse_ast.Unknown ("Cannot change default order once already set")

  let set_default_order_inc = set_default_order Ord_inc
  let set_default_order_dec = set_default_order Ord_dec

  let base_typ_of env typ =
    let rec aux (Typ_aux (t,a)) =
      let rewrap t = Typ_aux (t,a) in
      match t with
      | Typ_fn (t1, t2, eff) ->
        rewrap (Typ_fn (aux t1, aux t2, eff))
      | Typ_tup ts ->
        rewrap (Typ_tup (List.map aux ts))
      | Typ_app (r, [Typ_arg_aux (Typ_arg_typ rtyp,_)])
        when string_of_id r = "register" || string_of_id r = "ref" ->
        aux rtyp
      | Typ_app (id, targs) ->
        rewrap (Typ_app (id, List.map aux_arg targs))
      | t -> rewrap t
    and aux_arg (Typ_arg_aux (targ,a)) =
      let rewrap targ = Typ_arg_aux (targ,a) in
      match targ with
      | Typ_arg_typ typ -> rewrap (Typ_arg_typ (aux typ))
      | targ -> rewrap targ in
    aux (expand_synonyms env typ)

  let allow_polymorphic_undefineds env =
    { env with poly_undefineds = true }

  let polymorphic_undefineds env = env.poly_undefineds

  let pattern_completeness_ctx env =
    { Pattern_completeness.lookup_id = (fun id -> lookup_id id env);
      Pattern_completeness.enums = env.enums;
      Pattern_completeness.variants = Bindings.map (fun (_, tus) -> IdSet.of_list (List.map type_union_id tus)) env.variants
    }
end

let add_typquant l (quant : typquant) (env : Env.t) : Env.t =
  let rec add_quant_item env = function
    | QI_aux (qi, _) -> add_quant_item_aux env qi
  and add_quant_item_aux env = function
    | QI_const constr -> Env.add_constraint constr env
    | QI_id (KOpt_aux (KOpt_none kid, _)) -> Env.add_typ_var l kid BK_nat env
    | QI_id (KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (k, _)], _), kid), _)) -> Env.add_typ_var l kid k env
    | QI_id (KOpt_aux (_, l)) -> typ_error l "Type variable had non base kinds!"
  in
  match quant with
  | TypQ_aux (TypQ_no_forall, _) -> env
  | TypQ_aux (TypQ_tq quants, _) -> List.fold_left add_quant_item env quants

(* Create vectors with the default order from the environment *)

let default_order_error_string =
  "No default Order (if you have set a default Order, move it earlier in the specification)"

let dvector_typ env n typ = vector_typ n (Env.get_default_order env) typ

let destruct_exist env typ =
  match Env.canonicalize env typ with
  | Typ_aux (Typ_exist (kids, nc, typ), _) ->
     let fresh_kids = List.map (fun kid -> (kid, fresh_existential ~name:(string_of_id (id_of_kid kid)) ())) kids in
     let nc = List.fold_left (fun nc (kid, fresh) -> nc_subst_nexp kid (Nexp_var fresh) nc) nc fresh_kids in
     let typ = List.fold_left (fun typ (kid, fresh) -> typ_subst_nexp kid (Nexp_var fresh) typ) typ fresh_kids in
     Some (List.map snd fresh_kids, nc, typ)
  | _ -> None

let unwrap_exist env typ =
  match destruct_exist env typ with
  | Some (kids, nc, typ) -> (kids, nc, typ)
  | None -> ([], nc_true, typ)

let add_existential l kids nc env =
  let env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env kids in
  Env.add_constraint nc env

let add_typ_vars l kids env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env kids

let is_exist = function
  | Typ_aux (Typ_exist (_, _, _), _) -> true
  | _ -> false

let exist_typ constr typ =
  let fresh_kid = fresh_existential () in
  mk_typ (Typ_exist ([fresh_kid], constr fresh_kid, typ fresh_kid))

(** Destructure and canonicalise a numeric type into a list of type
   variables, a constraint on those type variables, and an
   N-expression that represents that numeric type in the
   environment. For example:

   - {'n, 'n <= 10. atom('n)} => ['n], 'n <= 10, 'n
   - int => ['n], true, 'n (where x is fresh)
   - atom('n) => [], true, 'n
**)
let destruct_numeric env typ =
  let typ = Env.canonicalize env typ in
  match destruct_exist env typ, typ with
  | Some (kids, nc, Typ_aux (Typ_app (id, [Typ_arg_aux (Typ_arg_nexp nexp, _)]), _)), _ when string_of_id id = "atom" ->
     Some (kids, nc, nexp)
  | None, Typ_aux (Typ_app (id, [Typ_arg_aux (Typ_arg_nexp nexp, _)]), _) ->
     Some ([], nc_true, nexp)
  | None, Typ_aux (Typ_id id, _) when string_of_id id = "int" ->
     let kid = fresh_existential () in
     Some ([kid], nc_true, nvar kid)
  | _, _ -> None

(** Pull an (potentially)-existentially qualified type into the global
   typing environment **)
let bind_existential l typ env =
  match destruct_numeric env typ with
  | Some (kids, nc, nexp) -> atom_typ nexp, add_existential l kids nc env
  | None -> match destruct_exist env typ with
            | Some (kids, nc, typ) -> typ, add_existential l kids nc env
            | None -> typ, env

let destruct_vector env typ =
  let destruct_vector' = function
    | Typ_aux (Typ_app (id, [Typ_arg_aux (Typ_arg_nexp n1, _);
                             Typ_arg_aux (Typ_arg_order o, _);
                             Typ_arg_aux (Typ_arg_typ vtyp, _)]
                       ), _) when string_of_id id = "vector" -> Some (nexp_simp n1, o, vtyp)
    | typ -> None
  in
  destruct_vector' (Env.expand_synonyms env typ)

let rec is_typ_monomorphic (Typ_aux (typ, _)) =
  match typ with
  | Typ_id _ -> true
  | Typ_tup typs -> List.for_all is_typ_monomorphic typs
  | Typ_app (id, args) -> List.for_all is_typ_arg_monomorphic args
  | Typ_fn (typ1, typ2, _) -> is_typ_monomorphic typ1 && is_typ_monomorphic typ2
  | Typ_exist _ | Typ_var _ -> false
and is_typ_arg_monomorphic (Typ_arg_aux (arg, _)) =
  match arg with
  | Typ_arg_nexp _ -> true
  | Typ_arg_typ typ -> is_typ_monomorphic typ
  | Typ_arg_order (Ord_aux (Ord_dec, _)) | Typ_arg_order (Ord_aux (Ord_inc, _)) -> true
  | Typ_arg_order (Ord_aux (Ord_var _, _)) -> false

(**************************************************************************)
(* 3. Subtyping and constraint solving                                    *)
(**************************************************************************)

(* Here's how the constraint generation works for subtyping

X(b,c...) --> {a. Y(a,b,c...)} \subseteq {a. Z(a,b,c...)}

this is equivalent to

\forall b c. X(b,c) --> \forall a. Y(a,b,c) --> Z(a,b,c)

\forall b c. X(b,c) --> \forall a. !Y(a,b,c) \/ !Z^-1(a,b,c)

\forall b c. X(b,c) --> !\exists a. Y(a,b,c) /\ Z^-1(a,b,c)

\forall b c. !X(b,c) \/ !\exists a. Y(a,b,c) /\ Z^-1(a,b,c)

!\exists b c. X(b,c) /\ \exists a. Y(a,b,c) /\ Z^-1(a,b,c)

!\exists a b c. X(b,c) /\ Y(a,b,c) /\ Z^-1(a,b,c)

which is then a problem we can feed to the constraint solver expecting unsat.
 *)

let rec nexp_constraint env var_of (Nexp_aux (nexp, l)) =
  match nexp with
  | Nexp_id v -> nexp_constraint env var_of (Env.get_num_def v env)
  | Nexp_var kid -> Constraint.variable (var_of kid)
  | Nexp_constant c -> Constraint.constant c
  | Nexp_times (nexp1, nexp2) -> Constraint.mult (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | Nexp_sum (nexp1, nexp2) -> Constraint.add (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | Nexp_minus (nexp1, nexp2) -> Constraint.sub (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | Nexp_exp nexp -> Constraint.pow2 (nexp_constraint env var_of nexp)
  | Nexp_neg nexp -> Constraint.sub (Constraint.constant (Big_int.of_int 0)) (nexp_constraint env var_of nexp)
  | Nexp_app (id, nexps) -> Constraint.app (Env.get_smt_op id env) (List.map (nexp_constraint env var_of) nexps)

let rec nc_constraint env var_of (NC_aux (nc, l)) =
  match nc with
  | NC_equal (nexp1, nexp2) -> Constraint.eq (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | NC_not_equal (nexp1, nexp2) -> Constraint.neq (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | NC_bounded_ge (nexp1, nexp2) -> Constraint.gteq (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | NC_bounded_le (nexp1, nexp2) -> Constraint.lteq (nexp_constraint env var_of nexp1) (nexp_constraint env var_of nexp2)
  | NC_set (_, []) -> Constraint.literal false
  | NC_set (kid, (int :: ints)) ->
     List.fold_left Constraint.disj
                    (Constraint.eq (nexp_constraint env var_of (nvar kid)) (Constraint.constant int))
                    (List.map (fun i -> Constraint.eq (nexp_constraint env var_of (nvar kid)) (Constraint.constant i)) ints)
  | NC_or (nc1, nc2) -> Constraint.disj (nc_constraint env var_of nc1) (nc_constraint env var_of nc2)
  | NC_and (nc1, nc2) -> Constraint.conj (nc_constraint env var_of nc1) (nc_constraint env var_of nc2)
  | NC_false -> Constraint.literal false
  | NC_true -> Constraint.literal true

let rec nc_constraints env var_of ncs =
  match ncs with
  | [] -> Constraint.literal true
  | [nc] -> nc_constraint env var_of nc
  | (nc :: ncs) ->
     Constraint.conj (nc_constraint env var_of nc) (nc_constraints env var_of ncs)

let prove_z3' env constr =
  let bindings = ref KBindings.empty  in
  let fresh_var kid =
    let n = KBindings.cardinal !bindings in
    bindings := KBindings.add kid n !bindings;
    n
  in
  let var_of kid =
    try KBindings.find kid !bindings with
    | Not_found -> fresh_var kid
  in
  let constr = Constraint.conj (nc_constraints env var_of (Env.get_constraints env)) (constr var_of) in
  match Constraint.call_z3 constr with
  | Constraint.Unsat -> typ_debug "unsat"; true
  | Constraint.Sat -> typ_debug "sat"; false
  | Constraint.Unknown -> typ_debug "unknown"; false

let prove_z3 env nc =
  typ_print ("Prove " ^ string_of_list ", " string_of_n_constraint (Env.get_constraints env) ^ " |- " ^ string_of_n_constraint nc);
  prove_z3' env (fun var_of -> Constraint.negate (nc_constraint env var_of nc))

let prove env (NC_aux (nc_aux, _) as nc) =
  let compare_const f (Nexp_aux (n1, _)) (Nexp_aux (n2, _)) =
    match n1, n2 with
    | Nexp_constant c1, Nexp_constant c2 when f c1 c2 -> true
    | _, _ -> false
  in
  match nc_aux with
  | NC_equal (nexp1, nexp2) when compare_const Big_int.equal (nexp_simp nexp1) (nexp_simp nexp2) -> true
  | NC_bounded_le (nexp1, nexp2) when compare_const Big_int.less_equal (nexp_simp nexp1) (nexp_simp nexp2) -> true
  | NC_bounded_ge (nexp1, nexp2) when compare_const Big_int.greater_equal (nexp_simp nexp1) (nexp_simp nexp2) -> true
  | NC_true -> true
  | _ -> prove_z3 env nc

(**************************************************************************)
(* 4. Unification                                                         *)
(**************************************************************************)

let rec nexp_frees ?exs:(exs=KidSet.empty) (Nexp_aux (nexp, l)) =
  match nexp with
  | Nexp_id _ -> KidSet.empty
  | Nexp_var kid -> KidSet.singleton kid
  | Nexp_constant _ -> KidSet.empty
  | Nexp_times (n1, n2) -> KidSet.union (nexp_frees ~exs:exs n1) (nexp_frees ~exs:exs n2)
  | Nexp_sum (n1, n2) -> KidSet.union (nexp_frees ~exs:exs n1) (nexp_frees ~exs:exs n2)
  | Nexp_minus (n1, n2) -> KidSet.union (nexp_frees ~exs:exs n1) (nexp_frees ~exs:exs n2)
  | Nexp_app (id, ns) -> List.fold_left KidSet.union KidSet.empty (List.map (fun n -> nexp_frees ~exs:exs n) ns)
  | Nexp_exp n -> nexp_frees ~exs:exs n
  | Nexp_neg n -> nexp_frees ~exs:exs n

let order_frees (Ord_aux (ord_aux, l)) =
  match ord_aux with
  | Ord_var kid -> KidSet.singleton kid
  | _ -> KidSet.empty

let rec typ_nexps (Typ_aux (typ_aux, l)) =
  match typ_aux with
  | Typ_id v -> []
  | Typ_var kid -> []
  | Typ_tup typs -> List.concat (List.map typ_nexps typs)
  | Typ_app (f, args) -> List.concat (List.map typ_arg_nexps args)
  | Typ_exist (kids, nc, typ) -> typ_nexps typ
  | Typ_fn (typ1, typ2, _) ->
     typ_nexps typ1 @ typ_nexps typ2
and typ_arg_nexps (Typ_arg_aux (typ_arg_aux, l)) =
  match typ_arg_aux with
  | Typ_arg_nexp n -> [n]
  | Typ_arg_typ typ -> typ_nexps typ
  | Typ_arg_order ord -> []

let rec typ_frees ?exs:(exs=KidSet.empty) (Typ_aux (typ_aux, l)) =
  match typ_aux with
  | Typ_id v -> KidSet.empty
  | Typ_var kid when KidSet.mem kid exs -> KidSet.empty
  | Typ_var kid -> KidSet.singleton kid
  | Typ_tup typs -> List.fold_left KidSet.union KidSet.empty (List.map (typ_frees ~exs:exs) typs)
  | Typ_app (f, args) -> List.fold_left KidSet.union KidSet.empty (List.map (typ_arg_frees ~exs:exs) args)
  | Typ_exist (kids, nc, typ) -> typ_frees ~exs:(KidSet.of_list kids) typ
  | Typ_fn (typ1, typ2, _) -> KidSet.union (typ_frees ~exs:exs typ1) (typ_frees ~exs:exs typ2)
and typ_arg_frees ?exs:(exs=KidSet.empty) (Typ_arg_aux (typ_arg_aux, l)) =
  match typ_arg_aux with
  | Typ_arg_nexp n -> nexp_frees ~exs:exs n
  | Typ_arg_typ typ -> typ_frees ~exs:exs typ
  | Typ_arg_order ord -> order_frees ord

let rec nexp_identical (Nexp_aux (nexp1, _)) (Nexp_aux (nexp2, _)) =
  match nexp1, nexp2 with
  | Nexp_id v1, Nexp_id v2 -> Id.compare v1 v2 = 0
  | Nexp_var kid1, Nexp_var kid2 -> Kid.compare kid1 kid2 = 0
  | Nexp_constant c1, Nexp_constant c2 -> Big_int.equal c1 c2
  | Nexp_times (n1a, n1b), Nexp_times (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | Nexp_sum (n1a, n1b), Nexp_sum (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | Nexp_minus (n1a, n1b), Nexp_minus (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | Nexp_exp n1, Nexp_exp n2 -> nexp_identical n1 n2
  | Nexp_neg n1, Nexp_neg n2 -> nexp_identical n1 n2
  | Nexp_app (f1, args1), Nexp_app (f2, args2) when List.length args1 = List.length args2 ->
     Id.compare f1 f2 = 0 && List.for_all2 nexp_identical args1 args2
  | _, _ -> false

let ord_identical (Ord_aux (ord1, _)) (Ord_aux (ord2, _)) =
  match ord1, ord2 with
  | Ord_var kid1, Ord_var kid2 -> Kid.compare kid1 kid2 = 0
  | Ord_inc, Ord_inc -> true
  | Ord_dec, Ord_dec -> true
  | _, _ -> false

let rec nc_identical (NC_aux (nc1, _)) (NC_aux (nc2, _)) =
  match nc1, nc2 with
  | NC_equal (n1a, n1b), NC_equal (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | NC_not_equal (n1a, n1b), NC_not_equal (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | NC_bounded_ge (n1a, n1b), NC_bounded_ge (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | NC_bounded_le (n1a, n1b), NC_bounded_le (n2a, n2b) -> nexp_identical n1a n2a && nexp_identical n1b n2b
  | NC_or (nc1a, nc1b), NC_or (nc2a, nc2b) -> nc_identical nc1a nc2a && nc_identical nc1b nc2b
  | NC_and (nc1a, nc1b), NC_and (nc2a, nc2b) -> nc_identical nc1a nc2a && nc_identical nc1b nc2b
  | NC_true, NC_true -> true
  | NC_false, NC_false -> true
  | NC_set (kid1, ints1), NC_set (kid2, ints2) when List.length ints1 = List.length ints2 ->
     Kid.compare kid1 kid2 = 0 && List.for_all2 (fun i1 i2 -> i1 = i2) ints1 ints2
  | _, _ -> false

let typ_identical env typ1 typ2 =
  let rec typ_identical' (Typ_aux (typ1, _)) (Typ_aux (typ2, _)) =
    match typ1, typ2 with
    | Typ_id v1, Typ_id v2 -> Id.compare v1 v2 = 0
    | Typ_var kid1, Typ_var kid2 -> Kid.compare kid1 kid2 = 0
    | Typ_tup typs1, Typ_tup typs2 ->
       begin
         try List.for_all2 typ_identical' typs1 typs2 with
         | Invalid_argument _ -> false
       end
    | Typ_app (f1, args1), Typ_app (f2, args2) ->
       begin
         try Id.compare f1 f2 = 0 && List.for_all2 typ_arg_identical args1 args2 with
         | Invalid_argument _ -> false
       end
    | Typ_exist (kids1, nc1, typ1), Typ_exist (kids2, nc2, typ2) when List.length kids1 = List.length kids2 ->
       List.for_all2 (fun k1 k2 -> Kid.compare k1 k2 = 0) kids1 kids2 && nc_identical nc1 nc2 && typ_identical' typ1 typ2
    | _, _ -> false
  and typ_arg_identical (Typ_arg_aux (arg1, _)) (Typ_arg_aux (arg2, _)) =
    match arg1, arg2 with
    | Typ_arg_nexp n1, Typ_arg_nexp n2 -> nexp_identical n1 n2
    | Typ_arg_typ typ1, Typ_arg_typ typ2 -> typ_identical' typ1 typ2
    | Typ_arg_order ord1, Typ_arg_order ord2 -> ord_identical ord1 ord2
    | _, _ -> false
  in
  typ_identical' (Env.expand_synonyms env typ1) (Env.expand_synonyms env typ2)

type uvar =
  | U_nexp of nexp
  | U_order of order
  | U_typ of typ

let uvar_subst_nexp sv subst = function
  | U_nexp nexp -> U_nexp (nexp_subst sv subst nexp)
  | U_typ typ -> U_typ (typ_subst_nexp sv subst typ)
  | U_order ord -> U_order ord

exception Unification_error of l * string;;

let unify_error l str = raise (Unification_error (l, str))

let rec unify_nexps l env goals (Nexp_aux (nexp_aux1, _) as nexp1) (Nexp_aux (nexp_aux2, _) as nexp2) =
  typ_debug ("UNIFYING NEXPS " ^ string_of_nexp nexp1 ^ " AND " ^ string_of_nexp nexp2 ^ " FOR GOALS " ^ string_of_list ", " string_of_kid (KidSet.elements goals));
  if KidSet.is_empty (KidSet.inter (nexp_frees nexp1) goals)
  then
    begin
      if prove env (NC_aux (NC_equal (nexp1, nexp2), Parse_ast.Unknown))
      then None
      else unify_error l ("Nexp " ^ string_of_nexp nexp1 ^ " and " ^ string_of_nexp nexp2 ^ " are not equal")
    end
  else
    match nexp_aux1 with
    | Nexp_id v -> unify_error l "Unimplemented Nexp_id in unify nexp"
    | Nexp_var kid when KidSet.mem kid goals -> Some (kid, nexp2)
    | Nexp_constant c1 ->
       begin
         match nexp_aux2 with
         | Nexp_constant c2 -> if c1 = c2 then None else unify_error l "Constants are not the same"
         | _ -> unify_error l "Unification error"
       end
    | _ -> unify_error l ("Cannot unify Int expression " ^ string_of_nexp nexp1 ^ " with " ^ string_of_nexp nexp2)

let string_of_uvar = function
  | U_nexp n -> string_of_nexp n
  | U_order o -> string_of_order o
  | U_typ typ -> string_of_typ typ

let unify_order l (Ord_aux (ord_aux1, _) as ord1) (Ord_aux (ord_aux2, _) as ord2) =
  typ_debug ("UNIFYING ORDERS " ^ string_of_order ord1 ^ " AND " ^ string_of_order ord2);
  match ord_aux1, ord_aux2 with
  | Ord_var kid, _ -> KBindings.singleton kid (U_order ord2)
  | Ord_inc, Ord_inc -> KBindings.empty
  | Ord_dec, Ord_dec -> KBindings.empty
  | _, _ -> unify_error l (string_of_order ord1 ^ " cannot be unified with " ^ string_of_order ord2)

let subst_unifiers unifiers typ =
  let subst_unifier typ (kid, uvar) =
    match uvar with
    | U_nexp nexp -> typ_subst_nexp kid (unaux_nexp nexp) typ
    | U_order ord -> typ_subst_order kid (unaux_order ord) typ
    | U_typ subst -> typ_subst_typ kid (unaux_typ subst) typ
  in
  List.fold_left subst_unifier typ (KBindings.bindings unifiers)

let subst_args_unifiers unifiers typ_args =
  let subst_unifier typ_args (kid, uvar) =
    match uvar with
    | U_nexp nexp -> List.map (typ_subst_arg_nexp kid (unaux_nexp nexp)) typ_args
    | U_order ord -> List.map (typ_subst_arg_order kid (unaux_order ord)) typ_args
    | U_typ subst -> List.map (typ_subst_arg_typ kid (unaux_typ subst)) typ_args
  in
  List.fold_left subst_unifier typ_args (KBindings.bindings unifiers)

let merge_unifiers l kid uvar1 uvar2 =
  match uvar1, uvar2 with
  | Some (U_nexp n1), Some (U_nexp n2) ->
     if nexp_identical n1 n2 then Some (U_nexp n1)
     else unify_error l ("Multiple non-identical unifiers for " ^ string_of_kid kid
                         ^ ": " ^ string_of_nexp n1 ^ " and " ^ string_of_nexp n2)
  | Some _, Some _ -> unify_error l "Multiple non-identical non-nexp unifiers"
  | None, Some u2 -> Some u2
  | Some u1, None -> Some u1
  | None, None -> None

let rec unify l env typ1 typ2 =
  typ_print (("Unify " |> Util.yellow |> Util.clear) ^ string_of_typ typ1 ^ " with " ^ string_of_typ typ2);
  assert (Env.is_canonical env typ1 && Env.is_canonical env typ2);
  let goals = KidSet.inter (KidSet.diff (typ_frees typ1) (typ_frees typ2)) (typ_frees typ1) in

  let rec unify_typ l (Typ_aux (typ1_aux, _) as typ1) (Typ_aux (typ2_aux, _) as typ2) =
    typ_debug ("UNIFYING TYPES " ^ string_of_typ typ1 ^ " AND " ^ string_of_typ typ2);
    match typ1_aux, typ2_aux with
    | Typ_id v1, Typ_id v2 ->
       if Id.compare v1 v2 = 0 then KBindings.empty
       else unify_error l (string_of_typ typ1 ^ " cannot be unified with " ^ string_of_typ typ2)
    | Typ_id v1, Typ_app (f2, []) ->
       if Id.compare v1 f2 = 0 then KBindings.empty
       else unify_error l (string_of_typ typ1 ^ " cannot be unified with " ^ string_of_typ typ2)
    | Typ_app (f1, []), Typ_id v2 ->
       if Id.compare f1 v2 = 0 then KBindings.empty
       else unify_error l (string_of_typ typ1 ^ " cannot be unified with " ^ string_of_typ typ2)
    | Typ_var kid, _ when KidSet.mem kid goals -> KBindings.singleton kid (U_typ typ2)
    | Typ_var kid1, Typ_var kid2 when Kid.compare kid1 kid2 = 0 -> KBindings.empty
    | Typ_tup typs1, Typ_tup typs2 ->
       begin
         try List.fold_left (KBindings.merge (merge_unifiers l)) KBindings.empty (List.map2 (unify_typ l) typs1 typs2) with
         | Invalid_argument _ -> unify_error l (string_of_typ typ1 ^ " cannot be unified with " ^ string_of_typ typ2
                                              ^ " tuple type is of different length")
       end
    | Typ_app (f1, args1), Typ_app (f2, args2) when Id.compare f1 f2 = 0 ->
       unify_typ_arg_list 0 KBindings.empty [] [] args1 args2
    | _, _ -> unify_error l (string_of_typ typ1 ^ " cannot be unified with " ^ string_of_typ typ2)

  and unify_typ_arg_list unified acc uargs1 uargs2 args1 args2 =
    match args1, args2 with
    | [], [] when unified = 0 && List.length uargs1 > 0 ->
       unify_error l "Could not unify arg lists" (*FIXME improve error *)
    | [], [] when unified > 0 && List.length uargs1 > 0 -> unify_typ_arg_list 0 acc [] [] uargs1 uargs2
    | [], [] when List.length uargs1 = 0 -> acc
    | (a1 :: a1s), (a2 :: a2s) ->
       begin
         let unifiers, success =
           try unify_typ_args l a1 a2, true with
           | Unification_error _ -> KBindings.empty, false
         in
         let a1s = subst_args_unifiers unifiers a1s in
         let a2s = subst_args_unifiers unifiers a2s in
         let uargs1 = subst_args_unifiers unifiers uargs1 in
         let uargs2 = subst_args_unifiers unifiers uargs2 in
         if success
         then unify_typ_arg_list (unified + 1) (KBindings.merge (merge_unifiers l) unifiers acc) uargs1 uargs2 a1s a2s
         else unify_typ_arg_list unified acc (a1 :: uargs1) (a2 :: uargs2) a1s a2s
       end
    | _, _ -> unify_error l "Cannot unify type lists of different length"

  and unify_typ_args l (Typ_arg_aux (typ_arg_aux1, _) as typ_arg1) (Typ_arg_aux (typ_arg_aux2, _) as typ_arg2) =
    match typ_arg_aux1, typ_arg_aux2 with
    | Typ_arg_nexp n1, Typ_arg_nexp n2 ->
       begin
         match unify_nexps l env goals (nexp_simp n1) (nexp_simp n2) with
         | Some (kid, unifier) -> KBindings.singleton kid (U_nexp (nexp_simp unifier))
         | None -> KBindings.empty
       end
    | Typ_arg_typ typ1, Typ_arg_typ typ2 -> unify_typ l typ1 typ2
    | Typ_arg_order ord1, Typ_arg_order ord2 -> unify_order l ord1 ord2
    | _, _ -> unify_error l (string_of_typ_arg typ_arg1 ^ " cannot be unified with type argument " ^ string_of_typ_arg typ_arg2)
  in

  match destruct_exist env typ2 with
  | Some (kids, nc, typ2) ->
     let typ1, typ2 = Env.expand_synonyms env typ1, Env.expand_synonyms env typ2 in
     let (unifiers, _, _) = unify l env typ1 typ2 in
     typ_debug (string_of_list ", " (fun (kid, uvar) -> string_of_kid kid ^ " => " ^ string_of_uvar uvar) (KBindings.bindings unifiers));
     unifiers, kids, Some nc
  | None ->
     let typ1, typ2 = Env.expand_synonyms env typ1, Env.expand_synonyms env typ2 in
     unify_typ l typ1 typ2, [], None

let merge_uvars l unifiers1 unifiers2 =
  try KBindings.merge (merge_unifiers l) unifiers1 unifiers2
  with
  | Unification_error (_, m) -> typ_error l ("Could not merge unification variables: " ^ m)

(**************************************************************************)
(* 4.5. Subtyping with existentials                                       *)
(**************************************************************************)

let destruct_atom_nexp env typ =
  match Env.expand_synonyms env typ with
  | Typ_aux (Typ_app (f, [Typ_arg_aux (Typ_arg_nexp n, _)]), _)
       when string_of_id f = "atom" -> Some n
  | _ -> None

let destruct_atom_kid env typ =
  match Env.expand_synonyms env typ with
  | Typ_aux (Typ_app (f, [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_var kid, _)), _)]), _)
       when string_of_id f = "atom" -> Some kid
  | _ -> None

let nc_subst_uvar kid uvar nc =
  match uvar with
  | U_nexp nexp -> nc_subst_nexp kid (unaux_nexp nexp) nc
  | _ -> nc

let uv_nexp_constraint env (kid, uvar) =
  match uvar with
  | U_nexp nexp -> Env.add_constraint (nc_eq (nvar kid) nexp) env
  | _ -> env

(* ***** Alpha-equivalence check ***** *)

(* It's important that alpha-equivalent types are always considered
   subtypes of one another, no matter how complex the types are, in
   order to ensure that the subtyping relation is reflexive. *)

(** The kid_order function takes a set of Int-kinded kids, and returns
   a list of those kids in the order they appear in a type, as well as
   a set containing all the kids that did not occur in the type. We
   only care about Int-kinded kids because those are the only type
   that can appear in an existential. *)
let rec kid_order_nexp kids (Nexp_aux (aux, l) as nexp) =
  match aux with
  | Nexp_var kid when KidSet.mem kid kids -> ([kid], KidSet.remove kid kids)
  | Nexp_var _ | Nexp_id _ | Nexp_constant _ -> ([], kids)
  | Nexp_exp nexp | Nexp_neg nexp -> kid_order_nexp kids nexp
  | Nexp_times (nexp1, nexp2) | Nexp_sum (nexp1, nexp2) | Nexp_minus (nexp1, nexp2) ->
     let (ord, kids) = kid_order_nexp kids nexp1 in
     let (ord', kids) = kid_order_nexp kids nexp2 in
     (ord @ ord', kids)
  | Nexp_app (id, nexps) ->
     List.fold_left (fun (ord, kids) nexp -> let (ord', kids) = kid_order_nexp kids nexp in (ord @ ord', kids)) ([], kids) nexps

let rec kid_order kids (Typ_aux (aux, l) as typ) =
  match aux with
  | Typ_var kid when KidSet.mem kid kids -> ([kid], KidSet.remove kid kids)
  | Typ_id _ | Typ_var _ -> ([], kids)
  | Typ_tup typs ->
     List.fold_left (fun (ord, kids) typ -> let (ord', kids) = kid_order kids typ in (ord @ ord', kids)) ([], kids) typs
  | Typ_app (_, args) ->
     List.fold_left (fun (ord, kids) arg -> let (ord', kids) = kid_order_arg kids arg in (ord @ ord', kids)) ([], kids) args
  | Typ_fn _ | Typ_exist _ -> typ_error l ("Existential or function type cannot appear within existential type: " ^ string_of_typ typ)
and kid_order_arg kids (Typ_arg_aux (aux, l) as arg) =
  match aux with
  | Typ_arg_typ typ -> kid_order kids typ
  | Typ_arg_nexp nexp -> kid_order_nexp kids nexp
  | Typ_arg_order _ -> ([], kids)

let rec alpha_equivalent env typ1 typ2 =
  let counter = ref 0 in
  let new_kid () = let kid = mk_kid ("alpha#" ^ string_of_int !counter) in (incr counter; kid) in

  let rec relabel (Typ_aux (aux, l) as typ) =
    let relabelled_aux =
      match aux with
      | Typ_id _ | Typ_var _ -> aux
      | Typ_fn (typ1, typ2, eff) -> Typ_fn (relabel typ1, relabel typ2, eff)
      | Typ_tup typs -> Typ_tup (List.map relabel typs)
      | Typ_exist (kids, nc, typ) ->
         let (kids, kids') = kid_order (KidSet.of_list kids) typ in
         (* FIXME: order kids' based of appearance in constraint *)
         let kids = List.map (fun kid -> (kid, new_kid ())) (kids @ KidSet.elements kids') in
         let nc = List.fold_left (fun nc (kid, nk) -> nc_subst_nexp kid (Nexp_var nk) nc) nc kids in
         let typ = List.fold_left (fun nc (kid, nk) -> typ_subst_nexp kid (Nexp_var nk) nc) typ kids in
         let kids = List.map snd kids in
         Typ_exist (kids, nc, typ)
      | Typ_app (id, args) ->
         Typ_app (id, List.map relabel_arg args)
    in
    Typ_aux (relabelled_aux, l)
  and relabel_arg (Typ_arg_aux (aux, l) as arg) =
    match aux with
    | Typ_arg_nexp _ | Typ_arg_order _ -> arg
    | Typ_arg_typ typ -> Typ_arg_aux (Typ_arg_typ (relabel typ), l)
  in

  let typ1 = relabel (Env.expand_synonyms env typ1) in
  counter := 0;
  let typ2 = relabel (Env.expand_synonyms env typ2) in
  typ_debug ("Alpha equivalence for " ^ string_of_typ typ1 ^ " and " ^ string_of_typ typ2);
  if typ_identical env typ1 typ2
  then (typ_debug "alpha-equivalent"; true)
  else (typ_debug "Not alpha-equivalent"; false)

(*

{'n 'm, A('n, 'm). atom('n)} <= {'n 'm, B('n 'm). atom('n)}

{'n | \exist 'm. A('n, 'm)} <= {'n | \exist 'm. B('n, 'm)}

\forall 'n. (\exist 'm. A('n, 'm)) --> (\exist 'm. B('n, 'm))
\forall 'n. (\forall 'm. \not A('n, 'm)) \/ (\exist 'm. B('n, 'm))
\forall 'n 'm. \not A('n, 'm) \/ (\exist 'm. B('n, 'm))

*)

let rec subtyp l env (Typ_aux (typ_aux1, _) as typ1) (Typ_aux (typ_aux2, _) as typ2) =
  typ_print (("Subtype " |> Util.green |> Util.clear) ^ string_of_typ typ1 ^ " and " ^ string_of_typ typ2);
  match typ_aux1, typ_aux2 with
  | Typ_tup typs1, Typ_tup typs2 when List.length typs1 = List.length typs2 ->
     List.iter2 (subtyp l env) typs1 typs2
  | _, _ ->
  match destruct_numeric env typ1, destruct_numeric env typ2 with
  (* Ensure alpha equivalent types are always subtypes of one another
     - this ensures that we can always re-check inferred types. *)
  | _, _ when alpha_equivalent env typ1 typ2 -> ()
  (* Special cases for two numeric (atom) types *)
  | Some (kids1, nc1, nexp1), Some ([], _, nexp2) ->
     let env = add_existential l kids1 nc1 env in
     if prove env (nc_eq nexp1 nexp2) then () else typ_error l "NCNE"
  | Some (kids1, nc1, nexp1), Some (kids2, nc2, nexp2) ->
     let env = add_existential l kids1 nc1 env in
     let env = add_typ_vars l (KidSet.elements (KidSet.inter (nexp_frees nexp2) (KidSet.of_list kids2))) env in
     let kids2 = KidSet.elements (KidSet.diff (KidSet.of_list kids2) (nexp_frees nexp2)) in
     let env = Env.add_constraint (nc_eq nexp1 nexp2) env in
     let constr var_of =
       Constraint.forall (List.map var_of kids2)
         (nc_constraint env var_of (nc_negate nc2))
     in
     if prove_z3' env constr then ()
     else typ_error l ("numeric subtyping failed")
  | _, _ ->
  match destruct_exist env typ1, unwrap_exist env typ2 with
  | Some (kids, nc, typ1), _ ->
     let env = add_existential l kids nc env in subtyp l env typ1 typ2
  | None, (kids, nc, typ2) ->
     let env = add_typ_vars l kids env in
     let kids' = KidSet.elements (KidSet.diff (KidSet.of_list kids) (typ_frees typ2)) in
     let unifiers, existential_kids, existential_nc =
       try unify l env typ2 typ1 with
       | Unification_error (_, m) -> typ_error l m
     in
     let nc = List.fold_left (fun nc (kid, uvar) -> nc_subst_uvar kid uvar nc) nc (KBindings.bindings unifiers) in
     let env = List.fold_left uv_nexp_constraint env (KBindings.bindings unifiers) in
     let env = match existential_kids, existential_nc with
       | [], None -> env
       | _, Some enc ->
          let env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env existential_kids in
          Env.add_constraint enc env
       | _, None -> assert false (* Cannot have existential_kids without existential_nc *)
     in
     let constr var_of =
       Constraint.forall (List.map var_of kids')
         (nc_constraint env var_of (nc_negate nc))
     in
     if prove_z3' env constr then ()
     else typ_error l ("Could not show " ^ string_of_typ typ1 ^ " is a subset of " ^ string_of_typ typ2)

let typ_equality l env typ1 typ2 =
  subtyp l env typ1 typ2; subtyp l env typ2 typ1

let subtype_check env typ1 typ2 =
  try subtyp Parse_ast.Unknown env typ1 typ2; true with
  | Type_error _ -> false

(**************************************************************************)
(* 5. Type checking expressions                                           *)
(**************************************************************************)

(* The type checker produces a fully annoted AST - tannot is the type
   of these type annotations. *)
type tannot = (Env.t * typ * effect) option

let infer_lit env (L_aux (lit_aux, l) as lit) =
  match lit_aux with
  | L_unit -> unit_typ
  | L_zero -> bit_typ
  | L_one -> bit_typ
  | L_num n -> atom_typ (nconstant n)
  | L_true -> bool_typ
  | L_false -> bool_typ
  | L_string _ -> string_typ
  | L_real _ -> real_typ
  | L_bin str ->
     begin
       match Env.get_default_order env with
       | Ord_aux (Ord_inc, _) | Ord_aux (Ord_dec, _) ->
          dvector_typ env (nint (String.length str)) (mk_typ (Typ_id (mk_id "bit")))
       | Ord_aux (Ord_var _, _) -> typ_error l default_order_error_string
     end
  | L_hex str ->
     begin
       match Env.get_default_order env with
       | Ord_aux (Ord_inc, _) | Ord_aux (Ord_dec, _) ->
          dvector_typ env (nint (String.length str * 4)) (mk_typ (Typ_id (mk_id "bit")))
       | Ord_aux (Ord_var _, _) -> typ_error l default_order_error_string
     end
  | L_undef -> typ_error l "Cannot infer the type of undefined"

let is_nat_kid kid = function
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_nat, _)], _), kid'), _) -> Kid.compare kid kid' = 0
  | KOpt_aux (KOpt_none kid', _) -> Kid.compare kid kid' = 0
  | _ -> false

let is_order_kid kid = function
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_order, _)], _), kid'), _) -> Kid.compare kid kid' = 0
  | _ -> false

let is_typ_kid kid = function
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_type, _)], _), kid'), _) -> Kid.compare kid kid' = 0
  | _ -> false

let rec instantiate_quants quants kid uvar = match quants with
  | [] -> []
  | ((QI_aux (QI_id kinded_id, _) as quant) :: quants) ->
     typ_debug ("instantiating quant " ^ string_of_quant_item quant);
     begin
       match uvar with
       | U_nexp nexp ->
          if is_nat_kid kid kinded_id
          then instantiate_quants quants kid uvar
          else quant :: instantiate_quants quants kid uvar
       | U_order ord ->
          if is_order_kid kid kinded_id
          then instantiate_quants quants kid uvar
          else quant :: instantiate_quants quants kid uvar
       | U_typ typ ->
          if is_typ_kid kid kinded_id
          then instantiate_quants quants kid uvar
          else quant :: instantiate_quants quants kid uvar
     end
  | ((QI_aux (QI_const nc, l)) :: quants) ->
     begin
       match uvar with
       | U_nexp nexp ->
          QI_aux (QI_const (nc_subst_nexp kid (unaux_nexp nexp) nc), l) :: instantiate_quants quants kid uvar
       | _ -> (QI_aux (QI_const nc, l)) :: instantiate_quants quants kid uvar
     end

let destruct_vector_typ l env typ =
  let destruct_vector_typ' l = function
    | Typ_aux (Typ_app (id, [Typ_arg_aux (Typ_arg_nexp n1, _);
                             Typ_arg_aux (Typ_arg_order o, _);
                             Typ_arg_aux (Typ_arg_typ vtyp, _)]
                       ), _) when string_of_id id = "vector" -> (n1, o, vtyp)
    | typ -> typ_error l ("Expected vector type, got " ^ string_of_typ typ)
  in
  destruct_vector_typ' l (Env.expand_synonyms env typ)

let env_of_annot (l, tannot) = match tannot with
  | Some (env, _, _) -> env
  | None -> raise (Reporting_basic.err_unreachable l "no type annotation")

let env_of (E_aux (_, (l, tannot))) = env_of_annot (l, tannot)

let typ_of_annot (l, tannot) = match tannot with
  | Some (_, typ, _) -> typ
  | None -> raise (Reporting_basic.err_unreachable l "no type annotation")

let env_of_annot (l, tannot) = match tannot with
  | Some (env, _, _) -> env
  | None -> raise (Reporting_basic.err_unreachable l "no type annotation")

let typ_of (E_aux (_, (l, tannot))) = typ_of_annot (l, tannot)
let env_of (E_aux (_, (l, tannot))) = env_of_annot (l, tannot)
let pat_typ_of (P_aux (_, (l, tannot))) = typ_of_annot (l, tannot)
let pat_env_of (P_aux (_, (l, tannot))) = env_of_annot (l, tannot)

(* Flow typing *)

let rec big_int_of_nexp (Nexp_aux (nexp, _)) = match nexp with
  | Nexp_constant c -> Some c
  | Nexp_times (n1, n2) ->
     Util.option_binop Big_int.add (big_int_of_nexp n1) (big_int_of_nexp n2)
  | Nexp_sum (n1, n2) ->
     Util.option_binop Big_int.add (big_int_of_nexp n1) (big_int_of_nexp n2)
  | Nexp_minus (n1, n2) ->
     Util.option_binop Big_int.add (big_int_of_nexp n1) (big_int_of_nexp n2)
  | Nexp_exp n ->
     Util.option_map (fun n -> Big_int.pow_int_positive 2 (Big_int.to_int n)) (big_int_of_nexp n)
  | _ -> None

let destruct_atom (Typ_aux (typ_aux, _)) =
  match typ_aux with
  | Typ_app (f, [Typ_arg_aux (Typ_arg_nexp nexp, _)])
       when string_of_id f = "atom" ->
     Util.option_map (fun c -> (c, nexp)) (big_int_of_nexp nexp)
  | Typ_app (f, [Typ_arg_aux (Typ_arg_nexp nexp1, _); Typ_arg_aux (Typ_arg_nexp nexp2, _)])
       when string_of_id f = "range" ->
     begin
       match big_int_of_nexp nexp1, big_int_of_nexp nexp2 with
       | Some c1, Some c2 -> if Big_int.equal c1 c2 then Some (c1, nexp1) else None
       | _ -> None
     end
  | _ -> None

exception Not_a_constraint;;

let rec assert_nexp env exp = destruct_atom_nexp env (typ_of exp)

let rec assert_constraint env (E_aux (exp_aux, _) as exp) =
  match exp_aux with
  | E_constraint nc ->
     Some nc
  | E_lit (L_aux (L_true, _)) -> Some nc_true
  | E_lit (L_aux (L_false, _)) -> Some nc_false
  | E_let (_,e) ->
     assert_constraint env e (* TODO: beware of fresh type vars *)
  | E_app (op, [x; y]) when string_of_id op = "or_bool" ->
     option_binop nc_or (assert_constraint env x) (assert_constraint env y)
  | E_app (op, [x; y]) when string_of_id op = "and_bool" ->
     option_binop nc_and (assert_constraint env x) (assert_constraint env y)
  | E_app (op, [x; y]) when string_of_id op = "gteq_atom" ->
     option_binop nc_gteq (assert_nexp env x) (assert_nexp env y)
  | E_app (op, [x; y]) when string_of_id op = "lteq_atom" ->
     option_binop nc_lteq (assert_nexp env x) (assert_nexp env y)
  | E_app (op, [x; y]) when string_of_id op = "gt_atom" ->
     option_binop nc_gt (assert_nexp env x) (assert_nexp env y)
  | E_app (op, [x; y]) when string_of_id op = "lt_atom" ->
     option_binop nc_lt (assert_nexp env x) (assert_nexp env y)
  | E_app (op, [x; y]) when string_of_id op = "eq_atom" ->
     option_binop nc_eq (assert_nexp env x) (assert_nexp env y)
  | E_app (op, [x; y]) when string_of_id op = "neq_atom" ->
     option_binop nc_neq (assert_nexp env x) (assert_nexp env y)
  | _ ->
     None

type flow_constraint =
  | Flow_lteq of Big_int.num * nexp
  | Flow_gteq of Big_int.num * nexp

let restrict_range_upper c1 nexp1 (Typ_aux (typ_aux, l) as typ) =
  match typ_aux with
  | Typ_app (f, [Typ_arg_aux (Typ_arg_nexp nexp, _); Typ_arg_aux (Typ_arg_nexp nexp2, _)])
     when string_of_id f = "range" ->
     begin
       match big_int_of_nexp nexp2 with
       | Some c2 ->
          let upper = if (Big_int.less c1 c2) then nexp1 else nexp2 in
          range_typ nexp upper
       | _ -> typ
     end
  | _ -> typ

let restrict_range_lower c1 nexp1 (Typ_aux (typ_aux, l) as typ) =
  match typ_aux with
  | Typ_app (f, [Typ_arg_aux (Typ_arg_nexp nexp2, _); Typ_arg_aux (Typ_arg_nexp nexp, _)])
     when string_of_id f = "range" ->
     begin
       match big_int_of_nexp nexp2 with
       | Some c2 ->
          let lower = if (Big_int.greater c1 c2) then nexp1 else nexp2 in
          range_typ lower nexp
       | _ -> typ
     end
  | _ -> typ

let apply_flow_constraint = function
  | Flow_lteq (c, nexp) ->
     (restrict_range_upper c nexp,
      restrict_range_lower (Big_int.succ c) (nexp_simp (nsum nexp (nint 1))))
  | Flow_gteq (c, nexp) ->
     (restrict_range_lower c nexp,
      restrict_range_upper (Big_int.pred c) (nexp_simp (nminus nexp (nint 1))))

let rec infer_flow env (E_aux (exp_aux, (l, _)) as exp) =
  match exp_aux with
  | E_app (f, [E_aux (E_id v, _); y]) when string_of_id f = "lt_range_atom" ->
     let kid = Env.fresh_kid env in
     begin
       match destruct_atom (typ_of y) with
       | Some (c, nexp) ->
          [(v, Flow_lteq (Big_int.pred c, nexp_simp (nminus nexp (nint 1))))], []
       | _ -> [], []
     end
  | E_app (f, [E_aux (E_id v, _); y]) when string_of_id f = "lteq_range_atom" ->
     let kid = Env.fresh_kid env in
     begin
       match destruct_atom (typ_of y) with
       | Some (c, nexp) -> [(v, Flow_lteq (c, nexp))], []
       | _ -> [], []
     end
  | E_app (f, [E_aux (E_id v, _); y]) when string_of_id f = "gt_range_atom" ->
     let kid = Env.fresh_kid env in
     begin
       match destruct_atom (typ_of y) with
       | Some (c, nexp) ->
          [(v, Flow_gteq (Big_int.succ c, nexp_simp (nsum nexp (nint 1))))], []
       | _ -> [], []
     end
  | E_app (f, [E_aux (E_id v, _); y]) when string_of_id f = "gteq_range_atom" ->
     let kid = Env.fresh_kid env in
     begin
       match destruct_atom (typ_of y) with
       | Some (c, nexp) -> [(v, Flow_gteq (c, nexp))], []
       | _ -> [], []
     end
  | _ -> [], option_these [assert_constraint env exp]

let rec add_flows b flows env =
  match flows with
  | [] -> env
  | (id, flow) :: flows when b -> add_flows true flows (Env.add_flow id (fst (apply_flow_constraint flow)) env)
  | (id, flow) :: flows -> add_flows false flows (Env.add_flow id (snd (apply_flow_constraint flow)) env)

let rec add_constraints constrs env =
  List.fold_left (fun env constr -> Env.add_constraint constr env) env constrs

(* When doing implicit type coercion, for performance reasons we want
   to filter out the possible casts to only those that could
   reasonably apply. We don't mind if we try some coercions that are
   impossible, but we should be careful to never rule out a possible
   cast - similar_typ and filter_casts implement this logic. It must be
   the case that if two types unify, then they match. *)
let rec similar_typ env typ1 typ2 =
  let Typ_aux (typ1_aux, _) = Env.expand_synonyms env typ1 in
  let Typ_aux (typ2_aux, _) = Env.expand_synonyms env typ2 in
  match typ1_aux, typ2_aux with
  | Typ_exist (_, _, typ1), _ -> similar_typ env typ1 typ2
  | _, Typ_exist (_, _, typ2) -> similar_typ env typ1 typ2
  | _, Typ_var kid2 -> true
  | Typ_id v1, Typ_id v2 when Id.compare v1 v2 = 0 -> true
  | Typ_tup typs1, Typ_tup typs2 -> List.for_all2 (similar_typ env) typs1 typs2
  | Typ_id v, Typ_app (f, _) when string_of_id v = "int" &&  string_of_id f = "atom" -> true
  | Typ_app (f1, _), Typ_app (f2, _) when Id.compare f1 f2 = 0 -> true
  | Typ_id v1, Typ_app (f2, _) when Id.compare v1 f2 = 0 -> true
  | Typ_app (f1, _), Typ_id v2 when Id.compare f1 v2 = 0 -> true
  | _, _ -> false

let rec filter_casts env from_typ to_typ casts =
  match casts with
  | (cast :: casts) ->
     begin
       let (quant, cast_typ) = Env.get_val_spec cast env in
       match cast_typ with
       | Typ_aux (Typ_fn (cast_from_typ, cast_to_typ, _), _)
            when similar_typ env from_typ cast_from_typ && similar_typ env to_typ cast_to_typ ->
          typ_print ("Considering cast " ^ string_of_typ cast_typ ^ " for " ^ string_of_typ from_typ ^ " to " ^ string_of_typ to_typ);
          cast :: filter_casts env from_typ to_typ casts
       | _ -> filter_casts env from_typ to_typ casts
     end
  | [] -> []

(* crule and irule are intended to wrap calls to check_exp and
   infer_exp. They add the tracing information and keep track of the
   depth, so that a type derivation tree can be constructed. *)

let crule r env exp typ =
  incr depth;
  typ_print (("Check" |> Util.cyan |> Util.clear) ^ " " ^ string_of_exp exp ^ " <= " ^ string_of_typ typ);
  try
    let checked_exp = r env exp typ in
    decr depth; checked_exp
  with
  | Type_error (l, err) -> decr depth; typ_raise l err

let irule r env exp =
  incr depth;
  try
    let inferred_exp = r env exp in
    typ_print (("Infer" |> Util.magenta |> Util.clear) ^ " " ^ string_of_exp exp ^ " => " ^ string_of_typ (typ_of inferred_exp));
    decr depth;
    inferred_exp
  with
  | Type_error (l, err) -> decr depth; typ_raise l err

let strip_exp : 'a exp -> unit exp = function exp -> map_exp_annot (fun (l, _) -> (l, ())) exp
let strip_pat : 'a pat -> unit pat = function pat -> map_pat_annot (fun (l, _) -> (l, ())) pat
let strip_pexp : 'a pexp -> unit pexp = function pexp -> map_pexp_annot (fun (l, _) -> (l, ())) pexp
let strip_lexp : 'a lexp -> unit lexp = function lexp -> map_lexp_annot (fun (l, _) -> (l, ())) lexp

let fresh_var =
  let counter = ref 0 in
  fun () -> let n = !counter in
            let () = counter := n+1 in
            mk_id ("v#" ^ string_of_int n)

let rec check_exp env (E_aux (exp_aux, (l, ())) as exp : unit exp) (Typ_aux (typ_aux, _) as typ) : tannot exp =
  let typ = Env.canonicalize env typ in
  let annot_exp_effect exp typ eff = E_aux (exp, (l, Some (env, Env.expand_synonyms env typ, eff))) in
  let add_effect exp eff = match exp with
    | (E_aux (exp, (l, Some (env, typ, _)))) -> E_aux (exp, (l, Some (env, typ, eff)))
    | _ -> failwith "Tried to add effect to unannoted expression"
  in
  let annot_exp exp typ = annot_exp_effect exp typ no_effect in
  match (exp_aux, typ_aux) with
  | E_block exps, _ ->
     begin
       let rec check_block l env exps typ =
         let annot_exp_effect exp typ eff = E_aux (exp, (l, Some (env, typ, eff))) in
         let annot_exp exp typ = annot_exp_effect exp typ no_effect in
         match exps with
         | [] -> typ_equality l env typ unit_typ; []
         | [exp] -> [crule check_exp env exp typ]
         | (E_aux (E_assign (lexp, bind), _) :: exps) ->
            let texp, env = bind_assignment env lexp bind in
            texp :: check_block l env exps typ
         | ((E_aux (E_assert (constr_exp, assert_msg), _) as exp) :: exps) ->
            let constr_exp = crule check_exp env constr_exp bool_typ in
            let checked_msg = crule check_exp env assert_msg string_typ in
            let env = match assert_constraint env constr_exp with
              | Some nc ->
                 typ_print ("Adding constraint " ^ string_of_n_constraint nc ^ " for assert");
                 Env.add_constraint nc env
              | None -> env
            in
            let texp = annot_exp_effect (E_assert (constr_exp, checked_msg)) unit_typ (mk_effect [BE_escape]) in
            texp :: check_block l env exps typ
         | (exp :: exps) ->
            let texp = crule check_exp env exp (mk_typ (Typ_id (mk_id "unit"))) in
            texp :: check_block l env exps typ
       in
       annot_exp (E_block (check_block l env exps typ)) typ
     end

  | E_case (exp, cases), _ ->
     Pattern_completeness.check l (Env.pattern_completeness_ctx env) cases;
     let inferred_exp = irule infer_exp env exp in
     let inferred_typ = typ_of inferred_exp in
     annot_exp (E_case (inferred_exp, List.map (fun case -> check_case env inferred_typ case typ) cases)) typ
  | E_try (exp, cases), _ ->
     let checked_exp = crule check_exp env exp typ in
     annot_exp (E_try (checked_exp, List.map (fun case -> check_case env exc_typ case typ) cases)) typ

  | E_cons (x, xs), _ ->
     begin match destruct_list typ with
     | Some elem_typ ->
        let checked_xs = crule check_exp env xs typ in
        let checked_x = crule check_exp env x elem_typ in
        annot_exp (E_cons (checked_x, checked_xs)) typ
     | None -> typ_error l ("Cons " ^ string_of_exp exp ^ " must have list type, got " ^ string_of_typ typ)
     end
  | E_list xs, _ ->
     begin match destruct_list typ with
     | Some elem_typ ->
        let checked_xs = List.map (fun x -> crule check_exp env x elem_typ) xs in
        annot_exp (E_list checked_xs) typ
     | None -> typ_error l ("List " ^ string_of_exp exp ^ " must have list type, got " ^ string_of_typ typ)
     end

  | E_record_update (exp, FES_aux (FES_Fexps (fexps, flag), (l, ()))), _ ->
     (* TODO: this could also infer exp - also fix code duplication with E_record below *)
     let checked_exp = crule check_exp env exp typ in
     let rectyp_id = match Env.expand_synonyms env typ with
       | Typ_aux (Typ_id rectyp_id, _) | Typ_aux (Typ_app (rectyp_id, _), _) when Env.is_record rectyp_id env ->
          rectyp_id
       | _ -> typ_error l ("The type " ^ string_of_typ typ ^ " is not a record")
     in
     let check_fexp (FE_aux (FE_Fexp (field, exp), (l, ()))) =
       let (typq, rectyp_q, field_typ, _) = Env.get_accessor rectyp_id field env in
       let unifiers, _, _ (* FIXME *) = try unify l env rectyp_q typ with Unification_error (l, m) -> typ_error l ("Unification error: " ^ m) in
       let field_typ' = subst_unifiers unifiers field_typ in
       let checked_exp = crule check_exp env exp field_typ' in
       FE_aux (FE_Fexp (field, checked_exp), (l, None))
     in
     annot_exp (E_record_update (checked_exp, FES_aux (FES_Fexps (List.map check_fexp fexps, flag), (l, None)))) typ
  | E_record (FES_aux (FES_Fexps (fexps, flag), (l, ()))), _ ->
     (* TODO: check record fields are total *)
     let rectyp_id = match Env.expand_synonyms env typ with
       | Typ_aux (Typ_id rectyp_id, _) | Typ_aux (Typ_app (rectyp_id, _), _) when Env.is_record rectyp_id env ->
          rectyp_id
       | _ -> typ_error l ("The type " ^ string_of_typ typ ^ " is not a record")
     in
     let check_fexp (FE_aux (FE_Fexp (field, exp), (l, ()))) =
       let (typq, rectyp_q, field_typ, _) = Env.get_accessor rectyp_id field env in
       let unifiers, _, _ (* FIXME *) = try unify l env rectyp_q typ with Unification_error (l, m) -> typ_error l ("Unification error: " ^ m) in
       let field_typ' = subst_unifiers unifiers field_typ in
       let checked_exp = crule check_exp env exp field_typ' in
       FE_aux (FE_Fexp (field, checked_exp), (l, None))
     in
     annot_exp (E_record (FES_aux (FES_Fexps (List.map check_fexp fexps, flag), (l, None)))) typ

  | E_let (LB_aux (letbind, (let_loc, _)), exp), _ ->
     begin
       match letbind with
       | LB_val (P_aux (P_typ (ptyp, _), _) as pat, bind) ->
          Env.wf_typ env ptyp;
          let checked_bind = crule check_exp env bind ptyp in
          let tpat, env = bind_pat_no_guard env pat ptyp in
          annot_exp (E_let (LB_aux (LB_val (tpat, checked_bind), (let_loc, None)), crule check_exp env exp typ)) typ
       | LB_val (pat, bind) ->
          let inferred_bind = irule infer_exp env bind in
          let tpat, env = bind_pat_no_guard env pat (typ_of inferred_bind) in
          annot_exp (E_let (LB_aux (LB_val (tpat, inferred_bind), (let_loc, None)), crule check_exp env exp typ)) typ
     end

  | E_app (f, [E_aux (E_constraint nc, _)]), _ when Id.compare f (mk_id "__prove") = 0 ->
     Env.wf_constraint env nc;
     if prove env nc
     then annot_exp (E_lit (L_aux (L_unit, Parse_ast.Unknown))) unit_typ
     else typ_error l ("Cannot prove " ^ string_of_n_constraint nc)
  | E_app (f, xs), _ when List.length (Env.get_overloads f env) > 0 ->
     let rec try_overload = function
       | (errs, []) -> typ_raise l (Err_no_overloading (f, errs))
       | (errs, (f :: fs)) -> begin
           typ_print (("Overload: " |> Util.red |> Util.clear) ^ string_of_id f ^ "(" ^ string_of_list ", " string_of_exp xs ^ ")");
           try crule check_exp env (E_aux (E_app (f, xs), (l, ()))) typ with
           | Type_error (_, err) ->
              typ_print ("Error : " ^ string_of_type_error err);
              try_overload (errs @ [(f, err)], fs)
         end
     in
     try_overload ([], Env.get_overloads f env)
  | E_app_infix (x, op, y), _ ->
     check_exp env (E_aux (E_app (deinfix op, [x; y]), (l, ()))) typ
  | E_app (f, xs), _ -> type_coercion env (infer_funapp l env f xs (Some typ)) typ

  | E_return exp, _ ->
     let checked_exp = match Env.get_ret_typ env with
       | Some ret_typ -> crule check_exp env exp ret_typ
       | None -> typ_error l "Cannot use return outside a function body"
     in
     annot_exp (E_return checked_exp) typ
  | E_exit exp, _ ->
     let checked_exp = crule check_exp env exp (mk_typ (Typ_id (mk_id "unit"))) in
     annot_exp_effect (E_exit checked_exp) typ (mk_effect [BE_escape])
  | E_throw exp, _ ->
     let checked_exp = crule check_exp env exp exc_typ in
     annot_exp_effect (E_throw checked_exp) typ (mk_effect [BE_escape])

  | E_if (cond, then_branch, else_branch), _ ->
     let cond' = crule check_exp env cond (mk_typ (Typ_id (mk_id "bool"))) in
     let flows, constrs = infer_flow env cond' in
     let then_branch' = crule check_exp (add_constraints constrs (add_flows true flows env)) then_branch typ in
     let else_branch' = crule check_exp (add_constraints (List.map nc_negate constrs) (add_flows false flows env)) else_branch typ in
     annot_exp (E_if (cond', then_branch', else_branch')) typ

  | E_var (lexp, bind, exp), _ ->
     let lexp, bind, env = match bind_assignment env lexp bind with
       | E_aux (E_assign (lexp, bind), _), env -> lexp, bind, env
       | _, _ -> assert false
     in
     let checked_exp = crule check_exp env exp typ in
     annot_exp (E_var (lexp, bind, checked_exp)) typ

  | E_internal_return exp, _ ->
     let checked_exp = crule check_exp env exp typ in
     annot_exp (E_internal_return checked_exp) typ
  | E_internal_plet (pat, bind, body), _ ->
     let bind_exp, ptyp = match pat with
       | P_aux (P_typ (ptyp, _), _) ->
          Env.wf_typ env ptyp;
          let checked_bind = crule check_exp env bind ptyp in
          checked_bind, ptyp
       | _ ->
          let inferred_bind = irule infer_exp env bind in
          inferred_bind, typ_of inferred_bind in
     let tpat, env = bind_pat_no_guard env pat ptyp in
     (* Propagate constraint assertions on the lhs of monadic binds to the rhs *)
     let env = match bind_exp with
       | E_aux (E_assert (constr_exp, _), _) ->
          begin
            match assert_constraint env constr_exp with
            | Some nc ->
               typ_print ("Adding constraint " ^ string_of_n_constraint nc ^ " for assert");
               Env.add_constraint nc env
            | None -> env
          end
       | _ -> env in
     let checked_body = crule check_exp env body typ in
     annot_exp (E_internal_plet (tpat, bind_exp, checked_body)) typ
  | E_vector vec, _ ->
     let (len, ord, vtyp) = destruct_vector_typ l env typ in
     let checked_items = List.map (fun i -> crule check_exp env i vtyp) vec in
     if prove env (nc_eq (nint (List.length vec)) (nexp_simp len)) then annot_exp (E_vector checked_items) typ
     else typ_error l ("Vector literal length didn't match type " ^ string_of_typ typ)

  (* undefined is the only literal that can't be inferred, only checked. *)
  | E_lit (L_aux (L_undef, _) as lit), _ ->
     if is_typ_monomorphic typ || Env.polymorphic_undefineds env
     then annot_exp_effect (E_lit lit) typ (mk_effect [BE_undef])
     else typ_error l ("Type " ^ string_of_typ typ ^ " failed undefined monomorphism restriction")
  | _, _ ->
     let inferred_exp = irule infer_exp env exp in
     type_coercion env inferred_exp typ

and check_case env pat_typ pexp typ =
  let pat,guard,case,((l,_) as annot) = destruct_pexp pexp in
  match bind_pat env pat pat_typ with
  | tpat, env, guards ->
     let guard = match guard, guards with
       | None, h::t -> Some (h,t)
       | Some x, l -> Some (x,l)
       | None, [] -> None
     in
     let guard = match guard with
       | Some (h,t) ->
          Some (List.fold_left (fun acc guard -> mk_exp (E_app_infix (acc, mk_id "&", guard))) h t)
       | None -> None
     in
     let checked_guard, env' = match guard with
       | None -> None, env
       | Some guard ->
          let checked_guard = check_exp env guard bool_typ in
          let flows, constrs = infer_flow env checked_guard in
          Some checked_guard, add_constraints constrs (add_flows true flows env)
     in
     let checked_case = crule check_exp env' case typ in
     construct_pexp (tpat, checked_guard, checked_case, (l, None))
  (* AA: Not sure if we still need this *)
  | exception (Type_error _ as typ_exn) ->
     match pat with
     | P_aux (P_lit lit, _) ->
        let guard' = mk_exp (E_app_infix (mk_exp (E_id (mk_id "p#")), mk_id "==", mk_exp (E_lit lit))) in
        let guard = match guard with
          | None -> guard'
          | Some guard -> mk_exp (E_app_infix (guard, mk_id "&", guard'))
        in
        check_case env pat_typ (Pat_aux (Pat_when (mk_pat (P_id (mk_id "p#")), guard, case), annot)) typ
     | _ -> raise typ_exn

(* type_coercion env exp typ takes a fully annoted (i.e. already type
   checked) expression exp, and attempts to cast (coerce) it to the
   type typ by inserting a coercion function that transforms the
   annotated expression into the correct type. Returns an annoted
   expression consisting of a type coercion function applied to exp,
   or throws a type error if the coercion cannot be performed. *)
and type_coercion env (E_aux (_, (l, _)) as annotated_exp) typ =
  let strip exp_aux = strip_exp (E_aux (exp_aux, (Parse_ast.Unknown, None))) in
  let annot_exp exp typ = E_aux (exp, (l, Some (env, typ, no_effect))) in
  let switch_typ exp typ = match exp with
    | (E_aux (exp, (l, Some (env, _, eff)))) -> E_aux (exp, (l, Some (env, typ, eff)))
    | _ -> failwith "Cannot switch type for unannotated function"
  in
  let rec try_casts trigger errs = function
    | [] -> typ_raise l (Err_no_casts (strip_exp annotated_exp, trigger, errs))
    | (cast :: casts) -> begin
        typ_print ("Casting with " ^ string_of_id cast ^ " expression " ^ string_of_exp annotated_exp ^ " to " ^ string_of_typ typ);
        try
          let checked_cast = crule check_exp (Env.no_casts env) (strip (E_app (cast, [annotated_exp]))) typ in
          annot_exp (E_cast (typ, checked_cast)) typ
        with
        | Type_error (_, err) -> try_casts trigger (err :: errs) casts
      end
  in
  begin
    try
      typ_debug ("PERFORMING TYPE COERCION: from " ^ string_of_typ (typ_of annotated_exp) ^ " to " ^ string_of_typ typ);
      subtyp l env (typ_of annotated_exp) typ; switch_typ annotated_exp typ
    with
    | Type_error (_, trigger) when Env.allow_casts env ->
       let casts = filter_casts env (typ_of annotated_exp) typ (Env.get_casts env) in
       try_casts trigger [] casts
    | Type_error (l, err) -> typ_error l "Subtype error"
  end

(* type_coercion_unify env exp typ attempts to coerce exp to a type
   exp_typ in the same way as type_coercion, except it is only
   required that exp_typ unifies with typ. Returns the annotated
   coercion as with type_coercion and also a set of unifiers, or
   throws a unification error *)
and type_coercion_unify env (E_aux (_, (l, _)) as annotated_exp) typ =
  let strip exp_aux = strip_exp (E_aux (exp_aux, (Parse_ast.Unknown, None))) in
  let annot_exp exp typ = E_aux (exp, (l, Some (env, typ, no_effect))) in
  let switch_typ exp typ = match exp with
    | (E_aux (exp, (l, Some (env, _, eff)))) -> E_aux (exp, (l, Some (env, typ, eff)))
    | _ -> failwith "Cannot switch type for unannotated expression"
  in
  let rec try_casts = function
    | [] -> unify_error l "No valid casts resulted in unification"
    | (cast :: casts) -> begin
        typ_print ("Casting with " ^ string_of_id cast ^ " expression " ^ string_of_exp annotated_exp ^ " for unification");
        try
          let inferred_cast = irule infer_exp (Env.no_casts env) (strip (E_app (cast, [annotated_exp]))) in
          let ityp = typ_of inferred_cast in
          annot_exp (E_cast (ityp, inferred_cast)) ityp, unify l env typ ityp
        with
        | Type_error (_, err) -> try_casts casts
        | Unification_error (_, err) -> try_casts casts
      end
  in
  begin
    try
      typ_debug "PERFORMING COERCING UNIFICATION";
      annotated_exp, unify l env typ (typ_of annotated_exp)
    with
    | Unification_error (_, m) when Env.allow_casts env ->
       let casts = filter_casts env (typ_of annotated_exp) typ (Env.get_casts env) in
       try_casts casts
  end

and bind_pat_no_guard env (P_aux (_,(l,_)) as pat) typ =
  match bind_pat env pat typ with
  | _, _, _::_ -> typ_error l "Literal patterns not supported here"
  | tpat, env, [] -> tpat, env

and bind_pat env (P_aux (pat_aux, (l, ())) as pat) typ =
  let (Typ_aux (typ_aux, _) as typ), env = bind_existential l typ env in
  typ_print (("Binding " |> Util.blue |> Util.clear) ^ string_of_pat pat ^  " to " ^ string_of_typ typ);
  let annot_pat pat typ = P_aux (pat, (l, Some (env, typ, no_effect))) in
  let switch_typ pat typ = match pat with
    | P_aux (pat_aux, (l, Some (env, _, eff))) -> P_aux (pat_aux, (l, Some (env, typ, eff)))
    | _ -> typ_error l "Cannot switch type for unannotated pattern"
  in
  let bind_tuple_pat (tpats, env, guards) pat typ =
    let tpat, env, guards' = bind_pat env pat typ in tpat :: tpats, env, guards' @ guards
  in
  match pat_aux with
  | P_id v ->
     begin
       (* If the identifier we're matching on is also a constructor of
          a union, that's probably a mistake, so warn about it. *)
       if Env.is_union_constructor v env then
         Util.warn (Printf.sprintf "Identifier %s found in pattern is also a union constructor at %s\n"
                                   (string_of_id v)
                                   (Reporting_basic.loc_to_string l))
       else ();
       match Env.lookup_id v env with
       | Local (Immutable, _) | Unbound -> annot_pat (P_id v) typ, Env.add_local v (Immutable, typ) env, []
       | Local (Mutable, _) | Register _ ->
          typ_error l ("Cannot shadow mutable local or register in switch statement pattern " ^ string_of_pat pat)
       | Enum enum -> subtyp l env enum typ; annot_pat (P_id v) typ, env, []
     end
  | P_var (pat, typ_pat) ->
     let env = bind_typ_pat env typ_pat typ in
     let typed_pat, env, guards = bind_pat env pat typ in
     annot_pat (P_var (typed_pat, typ_pat)) typ, env, guards
  | P_wild -> annot_pat P_wild typ, env, []
  | P_cons (hd_pat, tl_pat) ->
     begin
       match Env.expand_synonyms env typ with
       | Typ_aux (Typ_app (f, [Typ_arg_aux (Typ_arg_typ ltyp, _)]), _) when Id.compare f (mk_id "list") = 0 ->
          let hd_pat, env, hd_guards = bind_pat env hd_pat ltyp in
          let tl_pat, env, tl_guards = bind_pat env tl_pat typ in
          annot_pat (P_cons (hd_pat, tl_pat)) typ, env, hd_guards @ tl_guards
       | _ -> typ_error l "Cannot match cons pattern against non-list type"
     end
  | P_list pats ->
     begin
       match Env.expand_synonyms env typ with
       | Typ_aux (Typ_app (f, [Typ_arg_aux (Typ_arg_typ ltyp, _)]), _) when Id.compare f (mk_id "list") = 0 ->
          let rec process_pats env = function
            | [] -> [], env, []
            | (pat :: pats) ->
               let pat', env, guards = bind_pat env pat ltyp in
               let pats', env, guards' = process_pats env pats in
               pat' :: pats', env, guards @ guards'
          in
          let pats, env, guards = process_pats env pats in
          annot_pat (P_list pats) typ, env, guards
       | _ -> typ_error l ("Cannot match list pattern " ^ string_of_pat pat ^ "  against non-list type " ^ string_of_typ typ)
     end
  | P_tup [] ->
     begin
       match Env.expand_synonyms env typ with
       | Typ_aux (Typ_id typ_id, _) when string_of_id typ_id = "unit" ->
          annot_pat (P_tup []) typ, env, []
       | _ -> typ_error l "Cannot match unit pattern against non-unit type"
     end
  | P_tup pats ->
     begin
       match Env.expand_synonyms env typ with
       | Typ_aux (Typ_tup typs, _) ->
          let tpats, env, guards =
            try List.fold_left2 bind_tuple_pat ([], env, []) pats typs with
            | Invalid_argument _ -> typ_error l "Tuple pattern and tuple type have different length"
          in
          annot_pat (P_tup (List.rev tpats)) typ, env, guards
       | _ -> typ_error l "Cannot bind tuple pattern against non tuple type"
     end
  | P_app (f, pats) when Env.is_union_constructor f env ->
     begin
       let (typq, ctor_typ) = Env.get_val_spec f env in
       let quants = quant_items typq in
       let untuple (Typ_aux (typ_aux, _) as typ) = match typ_aux with
         | Typ_tup typs -> typs
         | _ -> [typ]
       in
       match Env.expand_synonyms env ctor_typ with
       | Typ_aux (Typ_fn (arg_typ, ret_typ, _), _) ->
          begin
            try
              typ_debug ("Unifying " ^ string_of_bind (typq, ctor_typ) ^ " for pattern " ^ string_of_typ typ);
              let unifiers, _, _ (* FIXME! *) = unify l env ret_typ typ in
              typ_debug (string_of_list ", " (fun (kid, uvar) -> string_of_kid kid ^ " => " ^ string_of_uvar uvar) (KBindings.bindings unifiers));
              let arg_typ' = subst_unifiers unifiers arg_typ in
              let quants' = List.fold_left (fun qs (kid, uvar) -> instantiate_quants qs kid uvar) quants (KBindings.bindings unifiers) in
              if (match quants' with [] -> false | _ -> true)
              then typ_error l ("Quantifiers " ^ string_of_list ", " string_of_quant_item quants' ^ " not resolved in pattern " ^ string_of_pat pat)
              else ();
              let ret_typ' = subst_unifiers unifiers ret_typ in
              let tpats, env, guards =
                try List.fold_left2 bind_tuple_pat ([], env, []) pats (untuple arg_typ') with
                | Invalid_argument _ -> typ_error l "Union constructor pattern arguments have incorrect length"
              in
              annot_pat (P_app (f, List.rev tpats)) typ, env, guards
            with
            | Unification_error (l, m) -> typ_error l ("Unification error when pattern matching against union constructor: " ^ m)
          end
       | _ -> typ_error l ("Mal-formed constructor " ^ string_of_id f)
     end
  | P_app (f, _) when not (Env.is_union_constructor f env) ->
     typ_error l (string_of_id f ^ " is not a union constructor in pattern " ^ string_of_pat pat)
  | P_as (pat, id) ->
     let (typed_pat, env, guards) = bind_pat env pat typ in
     annot_pat (P_as (typed_pat, id)) (pat_typ_of typed_pat), Env.add_local id (Immutable, pat_typ_of typed_pat) env, guards
  (* This is a special case for flow typing when we match a constant numeric literal. *)
  | P_lit (L_aux (L_num n, _) as lit) when is_atom typ ->
     subtyp l env (atom_typ (nconstant n)) typ;
     let nexp = match destruct_atom_nexp env typ with Some n -> n | None -> assert false in
     annot_pat (P_lit lit) (atom_typ (nconstant n)), Env.add_constraint (nc_eq nexp (nconstant n)) env, []
  | _ ->
     let (inferred_pat, env, guards) = infer_pat env pat in
     match subtyp l env typ (pat_typ_of inferred_pat) with
     | () -> switch_typ inferred_pat typ, env, guards
     | exception (Type_error _ as typ_exn) ->
        match pat_aux with
        | P_lit lit ->
           let var = fresh_var () in
           let guard = mk_exp (E_app_infix (mk_exp (E_id var), mk_id "==", mk_exp (E_lit lit))) in
           let (typed_pat, env, guards) = bind_pat env (mk_pat (P_id var)) typ in
           typed_pat, env, guard :: guards
        | _ -> raise typ_exn

and infer_pat env (P_aux (pat_aux, (l, ())) as pat) =
  let annot_pat pat typ = P_aux (pat, (l, Some (env, typ, no_effect))) in
  match pat_aux with
  | P_id v ->
     begin
       match Env.lookup_id v env with
       | Local (Immutable, _) | Unbound ->
          typ_error l ("Cannot infer identifier in pattern " ^ string_of_pat pat ^ " - try adding a type annotation")
       | Local (Mutable, _) | Register _ ->
          typ_error l ("Cannot shadow mutable local or register in switch statement pattern " ^ string_of_pat pat)
       | Enum enum -> annot_pat (P_id v) enum, env, []
     end
  | P_typ (typ_annot, pat) ->
     Env.wf_typ env typ_annot;
     let (typed_pat, env, guards) = bind_pat env pat typ_annot in
     annot_pat (P_typ (typ_annot, typed_pat)) typ_annot, env, guards
  | P_lit lit ->
     annot_pat (P_lit lit) (infer_lit env lit), env, []
  | P_vector (pat :: pats) ->
     let fold_pats (pats, env, guards) pat =
       let typed_pat, env, guards' = bind_pat env pat bit_typ in
       pats @ [typed_pat], env, guards' @ guards
     in
     let pats, env, guards = List.fold_left fold_pats ([], env, []) (pat :: pats) in
     let len = nexp_simp (nint (List.length pats)) in
     let etyp = pat_typ_of (List.hd pats) in
     List.iter (fun pat -> typ_equality l env etyp (pat_typ_of pat)) pats;
     annot_pat (P_vector pats) (dvector_typ env len etyp), env, guards
  | P_vector_concat (pat :: pats) ->
     let fold_pats (pats, env, guards) pat =
       let inferred_pat, env, guards' = infer_pat env pat in
       pats @ [inferred_pat], env, guards' @ guards
     in
     let inferred_pats, env, guards =
       List.fold_left fold_pats ([], env, []) (pat :: pats) in
     let (len, _, vtyp) = destruct_vector_typ l env (pat_typ_of (List.hd inferred_pats)) in
     let fold_len len pat =
       let (len', _, vtyp') = destruct_vector_typ l env (pat_typ_of pat) in
       typ_equality l env vtyp vtyp';
       nsum len len'
     in
     let len = nexp_simp (List.fold_left fold_len len (List.tl inferred_pats)) in
     annot_pat (P_vector_concat inferred_pats) (dvector_typ env len vtyp), env, guards
  | P_as (pat, id) ->
     let (typed_pat, env, guards) = infer_pat env pat in
     annot_pat (P_as (typed_pat, id)) (pat_typ_of typed_pat),
     Env.add_local id (Immutable, pat_typ_of typed_pat) env,
     guards
  | _ -> typ_error l ("Couldn't infer type of pattern " ^ string_of_pat pat)

and bind_typ_pat env (TP_aux (typ_pat_aux, l) as typ_pat) (Typ_aux (typ_aux, _) as typ) =
  match typ_pat_aux, typ_aux with
  | TP_wild, _ -> env
  | TP_var kid, _ ->
     begin
       match typ_nexps typ with
       | [nexp] ->
          Env.add_constraint (nc_eq (nvar kid) nexp) (Env.add_typ_var l kid BK_nat env)
       | [] ->
          typ_error l ("No numeric expressions in " ^ string_of_typ typ ^ " to bind " ^ string_of_kid kid ^ " to")
       | nexps ->
          typ_error l ("Type " ^ string_of_typ typ ^ " has multiple numeric expressions. Cannot bind " ^ string_of_kid kid)
     end
  | TP_app (f1, tpats), Typ_app (f2, typs) when Id.compare f1 f2 = 0 ->
     List.fold_left2 bind_typ_pat_arg env tpats typs
  | _, _ -> typ_error l ("Couldn't bind type " ^ string_of_typ typ ^ " with " ^ string_of_typ_pat typ_pat)
and bind_typ_pat_arg env (TP_aux (typ_pat_aux, l) as typ_pat) (Typ_arg_aux (typ_arg_aux, _) as typ_arg) =
  match typ_pat_aux, typ_arg_aux with
  | TP_wild, _ -> env
  | TP_var kid, Typ_arg_nexp nexp ->
     Env.add_constraint (nc_eq (nvar kid) nexp) (Env.add_typ_var l kid BK_nat env)
  | _, Typ_arg_typ typ -> bind_typ_pat env typ_pat typ
  | _, Typ_arg_order _ -> typ_error l "Cannot bind type pattern against order"
  | _, _ -> typ_error l ("Couldn't bind type argument " ^ string_of_typ_arg typ_arg ^ " with " ^ string_of_typ_pat typ_pat)

and bind_assignment env (LEXP_aux (lexp_aux, _) as lexp) (E_aux (_, (l, ())) as exp) =
  let annot_assign lexp exp = E_aux (E_assign (lexp, exp), (l, Some (env, mk_typ (Typ_id (mk_id "unit")), no_effect))) in
  let annot_lexp_effect lexp typ eff = LEXP_aux (lexp, (l, Some (env, typ, eff))) in
  let annot_lexp lexp typ = annot_lexp_effect lexp typ no_effect in
  let has_typ v env =
    match Env.lookup_id v env with
    | Local (Mutable, _) | Register _ -> true
    | _ -> false
  in
  match lexp_aux with
  | LEXP_field (LEXP_aux (flexp, _), field) ->
     begin
       let infer_flexp = function
         | LEXP_id v ->
            begin match Env.lookup_id v env with
            | Register typ -> typ, LEXP_id v, true
            | Local (Mutable, typ) -> typ, LEXP_id v, false
            | _ -> typ_error l "l-expression field is not a register or a local mutable type"
            end
         | LEXP_vector (LEXP_aux (LEXP_id v, _), exp) ->
            begin
              (* Check: is this ok if the vector is immutable? *)
              let is_immutable, vtyp, is_register = match Env.lookup_id v env with
                | Unbound -> typ_error l "Cannot assign to element of unbound vector"
                | Enum _ -> typ_error l "Cannot vector assign to enumeration element"
                | Local (Immutable, vtyp) -> true, vtyp, false
                | Local (Mutable, vtyp) -> false, vtyp, false
                | Register vtyp -> false, vtyp, true
              in
              let access = infer_exp (Env.enable_casts env) (E_aux (E_app (mk_id "vector_access", [E_aux (E_id v, (l, ())); exp]), (l, ()))) in
              let inferred_exp = match access with
                | E_aux (E_app (_, [_; inferred_exp]), _) -> inferred_exp
                | _ -> assert false
              in
              typ_of access, LEXP_vector (annot_lexp (LEXP_id v) vtyp, inferred_exp), is_register
            end
         | _ -> typ_error l "Field l-expression must be either a vector or an identifier"
       in
       let regtyp, inferred_flexp, is_register = infer_flexp flexp in
       typ_debug ("REGTYP: " ^ string_of_typ regtyp ^ " / " ^ string_of_typ (Env.expand_synonyms env regtyp));
       match Env.expand_synonyms env regtyp with
       | Typ_aux (Typ_id rectyp_id, _) | Typ_aux (Typ_app (rectyp_id, _), _) when Env.is_record rectyp_id env ->
          let eff = if is_register then mk_effect [BE_wreg] else no_effect in
          let (typq, rectyp_q, field_typ, _) = Env.get_accessor rectyp_id field env in
          let unifiers, _, _ (* FIXME *) = try unify l env rectyp_q regtyp with Unification_error (l, m) -> typ_error l ("Unification error: " ^ m) in
          let field_typ' = subst_unifiers unifiers field_typ in
          let checked_exp = crule check_exp env exp field_typ' in
          annot_assign (annot_lexp (LEXP_field (annot_lexp_effect inferred_flexp regtyp eff, field)) field_typ') checked_exp, env
       | _ ->  typ_error l "Field l-expression has invalid type"
     end
  | LEXP_memory (f, xs) ->
     check_exp env (E_aux (E_app (f, xs @ [exp]), (l, ()))) unit_typ, env
  | LEXP_cast (typ_annot, v) ->
     let checked_exp = crule check_exp env exp typ_annot in
     let tlexp, env' = bind_lexp env lexp (typ_of checked_exp) in
     annot_assign tlexp checked_exp, env'
  | LEXP_id v when has_typ v env ->
     begin match Env.lookup_id v env with
     | Local (Mutable, vtyp) | Register vtyp ->
        let checked_exp = crule check_exp env exp vtyp in
        let tlexp, env' = bind_lexp env lexp (typ_of checked_exp) in
        annot_assign tlexp checked_exp, env'
     | _ -> assert false
     end
  | _ ->
     let inferred_exp = irule infer_exp env exp in
     let tlexp, env' = bind_lexp env lexp (typ_of inferred_exp) in
     annot_assign tlexp inferred_exp, env'

and bind_lexp env (LEXP_aux (lexp_aux, (l, ())) as lexp) typ =
  let typ, env = bind_existential l typ env in
  let annot_lexp_effect lexp typ eff = LEXP_aux (lexp, (l, Some (env, Env.canonicalize env typ, eff))) in
  let annot_lexp lexp typ = annot_lexp_effect lexp typ no_effect in
  match lexp_aux with
  | LEXP_deref exp ->
     let inferred_exp = infer_exp env exp in
     begin match typ_of inferred_exp with
     | Typ_aux (Typ_app (r, [Typ_arg_aux (Typ_arg_typ vtyp, _)]), _) when string_of_id r = "ref" ->
        subtyp l env typ vtyp; annot_lexp (LEXP_deref inferred_exp) typ, env
     | Typ_aux (Typ_app (r, [Typ_arg_aux (Typ_arg_typ vtyp, _)]), _) when string_of_id r = "register" ->
        subtyp l env typ vtyp; annot_lexp_effect (LEXP_deref inferred_exp) typ (mk_effect [BE_wreg]), env
     | _ ->
        typ_error l (string_of_typ typ  ^ " must be a ref or register type in (*" ^ string_of_exp exp ^ ")")
     end
  | LEXP_id v ->
     begin match Env.lookup_id v env with
     | Local (Immutable, _) | Enum _ ->
        typ_error l ("Cannot modify let-bound constant or enumeration constructor " ^ string_of_id v)
     | Local (Mutable, vtyp) -> subtyp l env typ vtyp; annot_lexp (LEXP_id v) typ, env
     | Register vtyp -> subtyp l env typ vtyp; annot_lexp_effect (LEXP_id v) typ (mk_effect [BE_wreg]), env
     | Unbound -> annot_lexp (LEXP_id v) typ, Env.add_local v (Mutable, typ) env
     end
  | LEXP_cast (typ_annot, v) ->
     begin
       match Env.lookup_id v env with
       | Local (Immutable, _) | Enum _ ->
          typ_error l ("Cannot modify let-bound constant or enumeration constructor " ^ string_of_id v)
       | Local (Mutable, vtyp) ->
          begin
            subtyp l env typ typ_annot;
            subtyp l env typ_annot vtyp;
            annot_lexp (LEXP_cast (typ_annot, v)) typ, Env.add_local v (Mutable, typ_annot) env
          end
       | Register vtyp ->
          begin
            subtyp l env typ typ_annot;
            subtyp l env typ_annot vtyp;
            annot_lexp_effect (LEXP_cast (typ_annot, v)) typ (mk_effect [BE_wreg]), env
          end
       | Unbound ->
          begin
            subtyp l env typ typ_annot;
            annot_lexp (LEXP_cast (typ_annot, v)) typ, Env.add_local v (Mutable, typ_annot) env
          end
     end
  | LEXP_tup lexps ->
     begin
       let typ = Env.expand_synonyms env typ in
       let (Typ_aux (typ_aux, _)) = typ in
       match typ_aux with
       | Typ_tup typs ->
          let bind_tuple_lexp lexp typ (tlexps, env) =
            let tlexp, env = bind_lexp env lexp typ in tlexp :: tlexps, env
          in
          let tlexps, env =
            try List.fold_right2 bind_tuple_lexp lexps typs ([], env) with
            | Invalid_argument _ -> typ_error l "Tuple l-expression and tuple type have different length"
          in
          annot_lexp (LEXP_tup tlexps) typ, env
       (* This case is pretty much just for the PSTATE.<N,Z,C,V> := vector pattern which is really common in ASL. *)
       (* Maybe this code can be made not horrible? *)
       | Typ_app (id, _) when Id.compare id (mk_id "vector") == 0 ->
          begin
            match destruct_vector env typ with
            | Some (vec_len, _, _) ->
               let bind_bits_tuple lexp (tlexps, env, llen) =
                 match lexp with
                 | LEXP_aux (LEXP_id v, _) ->
                    begin
                      match Env.lookup_id v env with
                      | Local (Immutable, _) | Enum _ ->
                         typ_error l ("Cannot modify let-bound constant or enumeration constructor " ^ string_of_id v)
                      | Unbound ->
                         typ_error l "Unbound variable in vector tuple assignment"
                      | Local (Mutable, vtyp) | Register vtyp ->
                         let llen' = match destruct_vector env vtyp with
                           | Some (llen', _, _) -> llen'
                           | None -> typ_error l "Variables in vector tuple assignment must be vectors"
                         in
                         let tlexp, env = bind_lexp env lexp vtyp in
                         tlexp :: tlexps, env, nsum llen llen'
                    end
                 | LEXP_aux (LEXP_field (LEXP_aux (LEXP_id v, _), fid), _) ->
                   (* FIXME: will only work for ASL *)
                   let rec_id =
                     match Env.lookup_id v env with
                     | Register (Typ_aux (Typ_id rec_id, _)) -> rec_id
                     | _ -> typ_error l (string_of_lexp lexp ^ " must be a record register here")
                   in
                   let typq, _, vtyp, _ = Env.get_accessor rec_id fid env in
                   let llen' = match destruct_vector env vtyp with
                     | Some (llen', _, _) -> llen'
                     | None -> typ_error l "Variables in vector tuple assignment must be vectors"
                   in
                   let tlexp, env = bind_lexp env lexp vtyp in
                   tlexp :: tlexps, env, nsum llen llen'
                 | _ -> typ_error l "bit vector assignment must only contain identifiers"
               in
               let tlexps, env, lexp_len = List.fold_right bind_bits_tuple lexps ([], env, nint 0) in
               if prove env (nc_eq vec_len lexp_len)
               then annot_lexp (LEXP_tup tlexps) typ, env
               else typ_error l "Vector and tuple length must be the same in assignment"
            | None -> typ_error l ("Malformed vector type " ^ string_of_typ typ)
          end
       | _ -> typ_error l ("Cannot bind tuple l-expression against non tuple or vector type " ^ string_of_typ typ)
     end
  | LEXP_vector_range (LEXP_aux (LEXP_id v, _), exp1, exp2) ->
     begin
       let is_register, vtyp = match Env.lookup_id v env with
         | Unbound -> typ_error l "Cannot assign to element of unbound vector"
         | Enum _ -> typ_error l "Cannot vector assign to enumeration element"
         | Local (Immutable, vtyp) -> typ_error l "Cannot vector assign to immutable variable"
         | Local (Mutable, vtyp) -> false, vtyp
         | Register vtyp -> true, vtyp
       in
       let inferred_exp1, inferred_exp2 = irule infer_exp env exp1, irule infer_exp env exp2 in
       match destruct_numeric env (typ_of inferred_exp1), destruct_numeric env (typ_of inferred_exp2) with
       | Some (kids1, nc1, nexp1), Some (kids2, nc2, nexp2) ->
          let kid = fresh_existential () in
          let env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env (kid :: kids1 @ kids2) in
          let env = Env.add_constraint (nc_and nc1 nc2) env in
          let subrange_len = nminus nexp1 (nminus nexp2 (nint 1)) in
          let env = Env.add_constraint (nc_eq (nvar kid) subrange_len) env in
          subtyp l env typ (vector_typ subrange_len dec_ord bit_typ);
          if is_register then
            annot_lexp (LEXP_vector_range (annot_lexp_effect (LEXP_id v) vtyp (mk_effect [BE_wreg]), inferred_exp1, inferred_exp2)) typ, env
          else
            annot_lexp (LEXP_vector_range (annot_lexp (LEXP_id v) vtyp, inferred_exp1, inferred_exp2)) typ, env
       | _, _ -> typ_error l ("Bad vector assignment: " ^ string_of_lexp lexp)
     end
  (* Not sure about this case... can the left lexp be anything other than an identifier? *)
  | LEXP_vector (LEXP_aux (LEXP_id v, _), exp) ->
     begin
       let is_immutable, is_register, vtyp = match Env.lookup_id v env with
         | Unbound -> typ_error l "Cannot assign to element of unbound vector"
         | Enum _ -> typ_error l "Cannot vector assign to enumeration element"
         | Local (Immutable, vtyp) -> true, false, vtyp
         | Local (Mutable, vtyp) -> false, false, vtyp
         | Register vtyp -> false, true, vtyp
       in
       let access = infer_exp (Env.enable_casts env) (E_aux (E_app (mk_id "vector_access", [E_aux (E_id v, (l, ())); exp]), (l, ()))) in
       let inferred_exp = match access with
         | E_aux (E_app (_, [_; inferred_exp]), _) -> inferred_exp
         | _ -> assert false
       in
       match typ_of access with
       | _ when not is_immutable && is_register ->
          subtyp l env typ (typ_of access);
          annot_lexp (LEXP_vector (annot_lexp_effect (LEXP_id v) vtyp (mk_effect [BE_wreg]), inferred_exp)) typ, env
       | _ when not is_immutable ->
          subtyp l env typ (typ_of access);
          annot_lexp (LEXP_vector (annot_lexp (LEXP_id v) vtyp, inferred_exp)) typ, env
       | _ -> typ_error l ("Bad vector assignment: " ^ string_of_lexp lexp)
     end
  | LEXP_field (LEXP_aux (LEXP_id v, _), fid) ->
     (* FIXME: will only work for ASL *)
     let rec_id =
       match Env.lookup_id v env with
       | Register (Typ_aux (Typ_id rec_id, _)) -> rec_id
       | _ -> typ_error l (string_of_lexp lexp ^ " must be a record register here")
     in
     let typq, _, ret_typ, _ = Env.get_accessor rec_id fid env in
     annot_lexp_effect (LEXP_field (annot_lexp (LEXP_id v) (mk_id_typ rec_id), fid)) ret_typ (mk_effect [BE_wreg]), env
  | _ -> typ_error l ("Unhandled l-expression " ^ string_of_lexp lexp)

and infer_exp env (E_aux (exp_aux, (l, ())) as exp) =
  let annot_exp_effect exp typ eff = E_aux (exp, (l, Some (env, Env.canonicalize env typ, eff))) in
  let annot_exp exp typ = annot_exp_effect exp typ no_effect in
  match exp_aux with
  | E_nondet exps ->
     annot_exp (E_nondet (List.map (fun exp -> crule check_exp env exp unit_typ) exps)) unit_typ
  | E_id v ->
     begin
       match Env.lookup_id v env with
       | Local (_, typ) | Enum typ -> annot_exp (E_id v) typ
       | Register typ -> annot_exp_effect (E_id v) typ (mk_effect [BE_rreg])
       | Unbound -> typ_error l ("Identifier " ^ string_of_id v ^ " is unbound")
     end
  | E_lit lit -> annot_exp (E_lit lit) (infer_lit env lit)
  | E_sizeof nexp -> annot_exp (E_sizeof nexp) (mk_typ (Typ_app (mk_id "atom", [mk_typ_arg (Typ_arg_nexp nexp)])))
  | E_constraint nc ->
     Env.wf_constraint env nc;
     annot_exp (E_constraint nc) bool_typ
  | E_field (exp, field) ->
     begin
       let inferred_exp = irule infer_exp env exp in
       match Env.expand_synonyms env (typ_of inferred_exp) with
       (* Accessing a field of a record *)
       | Typ_aux (Typ_id rectyp, _) as typ when Env.is_record rectyp env ->
          begin
            let inferred_acc, _ = infer_funapp' l (Env.no_casts env) field (Env.get_accessor_fn rectyp field env) [strip_exp inferred_exp] None in
            match inferred_acc with
            | E_aux (E_app (field, [inferred_exp]) ,_) -> annot_exp (E_field (inferred_exp, field)) (typ_of inferred_acc)
            | _ -> assert false (* Unreachable *)
          end
       (* Not sure if we need to do anything different with args here. *)
       | Typ_aux (Typ_app (rectyp, args), _) as typ when Env.is_record rectyp env ->
          begin
            let inferred_acc, _ = infer_funapp' l (Env.no_casts env) field (Env.get_accessor_fn rectyp field env) [strip_exp inferred_exp] None in
            match inferred_acc with
            | E_aux (E_app (field, [inferred_exp]) ,_) -> annot_exp (E_field (inferred_exp, field)) (typ_of inferred_acc)
            | _ -> assert false (* Unreachable *)
          end
       | _ ->  typ_error l ("Field expression " ^ string_of_exp exp ^ " :: " ^ string_of_typ (typ_of inferred_exp) ^ " is not valid")
     end
  | E_tuple exps ->
     let inferred_exps = List.map (irule infer_exp env) exps in
     annot_exp (E_tuple inferred_exps) (mk_typ (Typ_tup (List.map typ_of inferred_exps)))
  | E_assign (lexp, bind) ->
     fst (bind_assignment env lexp bind)
  | E_record_update (exp, FES_aux (FES_Fexps (fexps, flag), (l, ()))) ->
     let inferred_exp = irule infer_exp env exp in
     let typ = typ_of inferred_exp in
     let rectyp_id = match Env.expand_synonyms env typ with
       | Typ_aux (Typ_id rectyp_id, _) | Typ_aux (Typ_app (rectyp_id, _), _) when Env.is_record rectyp_id env ->
          rectyp_id
       | _ -> typ_error l ("The type " ^ string_of_typ typ ^ " is not a record")
     in
     let check_fexp (FE_aux (FE_Fexp (field, exp), (l, ()))) =
       let (typq, rectyp_q, field_typ, _) = Env.get_accessor rectyp_id field env in
       let unifiers, _, _ (* FIXME *) = try unify l env rectyp_q typ with Unification_error (l, m) -> typ_error l ("Unification error: " ^ m) in
       let field_typ' = subst_unifiers unifiers field_typ in
       let inferred_exp = crule check_exp env exp field_typ' in
       FE_aux (FE_Fexp (field, inferred_exp), (l, None))
     in
     annot_exp (E_record_update (inferred_exp, FES_aux (FES_Fexps (List.map check_fexp fexps, flag), (l, None)))) typ
  | E_cast (typ, exp) ->
     let checked_exp = crule check_exp env exp typ in
     annot_exp (E_cast (typ, checked_exp)) typ
  | E_app_infix (x, op, y) -> infer_exp env (E_aux (E_app (deinfix op, [x; y]), (l, ())))
  | E_app (f, xs) when List.length (Env.get_overloads f env) > 0 ->
     let rec try_overload = function
       | (errs, []) -> typ_raise l (Err_no_overloading (f, errs))
       | (errs, (f :: fs)) -> begin
           typ_print ("Overload: " ^ string_of_id f ^ "(" ^ string_of_list ", " string_of_exp xs ^ ")");
           try irule infer_exp env (E_aux (E_app (f, xs), (l, ()))) with
           | Type_error (_, err) ->
              typ_print ("Error : " ^ string_of_type_error err);
              try_overload (errs @ [(f, err)], fs)
         end
     in
     try_overload ([], Env.get_overloads f env)
  | E_app (f, xs) -> infer_funapp l env f xs None
  | E_loop (loop_type, cond, body) ->
     let checked_cond = crule check_exp env cond bool_typ in
     let checked_body = crule check_exp env body unit_typ in
     annot_exp (E_loop (loop_type, checked_cond, checked_body)) unit_typ
  | E_for (v, f, t, step, ord, body) ->
     begin
       let f, t, is_dec = match ord with
         | Ord_aux (Ord_inc, _) -> f, t, false
         | Ord_aux (Ord_dec, _) -> t, f, true (* reverse direction to typechecking downto as upto loop *)
         | Ord_aux (Ord_var _, _) -> typ_error l "Cannot check a loop with variable direction!" (* This should never happen *)
       in
       let inferred_f = irule infer_exp env f in
       let inferred_t = irule infer_exp env t in
       let checked_step = crule check_exp env step int_typ in
       match destruct_numeric env (typ_of inferred_f), destruct_numeric env (typ_of inferred_t) with
       | Some (kids1, nc1, nexp1), Some (kids2, nc2, nexp2) ->
          let loop_kid = mk_kid ("loop_" ^ string_of_id v) in
          let env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env (loop_kid :: kids1 @ kids2) in
          let env = Env.add_constraint (nc_and nc1 nc2) env in
          let env = Env.add_constraint (nc_and (nc_lteq nexp1 (nvar loop_kid)) (nc_lteq (nvar loop_kid) nexp2)) env in
          let loop_vtyp = atom_typ (nvar loop_kid) in
          let checked_body = crule check_exp (Env.add_local v (Immutable, loop_vtyp) env) body unit_typ in
          if not is_dec (* undo reverse direction in annotated ast for downto loop *)
          then annot_exp (E_for (v, inferred_f, inferred_t, checked_step, ord, checked_body)) unit_typ
          else annot_exp (E_for (v, inferred_t, inferred_f, checked_step, ord, checked_body)) unit_typ
       | _, _ -> typ_error l "Ranges in foreach overlap"
     end
  | E_if (cond, then_branch, else_branch) ->
     let cond' = crule check_exp env cond (mk_typ (Typ_id (mk_id "bool"))) in
     let flows, constrs = infer_flow env cond' in
     let then_branch' = irule infer_exp (add_constraints constrs (add_flows true flows env)) then_branch in
     let else_branch' = crule check_exp (add_constraints (List.map nc_negate constrs) (add_flows false flows env)) else_branch (typ_of then_branch') in
     annot_exp (E_if (cond', then_branch', else_branch')) (typ_of then_branch')
  | E_vector_access (v, n) -> infer_exp env (E_aux (E_app (mk_id "vector_access", [v; n]), (l, ())))
  | E_vector_update (v, n, exp) -> infer_exp env (E_aux (E_app (mk_id "vector_update", [v; n; exp]), (l, ())))
  | E_vector_update_subrange (v, n, m, exp) -> infer_exp env (E_aux (E_app (mk_id "vector_update_subrange", [v; n; m; exp]), (l, ())))
  | E_vector_append (v1, v2) -> infer_exp env (E_aux (E_app (mk_id "append", [v1; v2]), (l, ())))
  | E_vector_subrange (v, n, m) -> infer_exp env (E_aux (E_app (mk_id "vector_subrange", [v; n; m]), (l, ())))
  | E_vector [] -> typ_error l "Cannot infer type of empty vector"
  | E_vector ((item :: items) as vec) ->
     let inferred_item = irule infer_exp env item in
     let checked_items = List.map (fun i -> crule check_exp env i (typ_of inferred_item)) items in
     let vec_typ = dvector_typ env (nint (List.length vec)) (typ_of inferred_item) in
     annot_exp (E_vector (inferred_item :: checked_items)) vec_typ
  | E_assert (test, msg) ->
     let checked_test = crule check_exp env test bool_typ in
     let checked_msg = crule check_exp env msg string_typ in
     annot_exp_effect (E_assert (checked_test, checked_msg)) unit_typ (mk_effect [BE_escape])
  | E_internal_return exp ->
     let inferred_exp = irule infer_exp env exp in
     annot_exp (E_internal_return inferred_exp) (typ_of inferred_exp)
  | E_internal_plet (pat, bind, body) ->
     let bind_exp, ptyp = match pat with
       | P_aux (P_typ (ptyp, _), _) ->
          Env.wf_typ env ptyp;
          let checked_bind = crule check_exp env bind ptyp in
          checked_bind, ptyp
       | _ ->
          let inferred_bind = irule infer_exp env bind in
          inferred_bind, typ_of inferred_bind in
     let tpat, env = bind_pat_no_guard env pat ptyp in
     (* Propagate constraint assertions on the lhs of monadic binds to the rhs *)
     let env = match bind_exp with
       | E_aux (E_assert (constr_exp, _), _) ->
          begin
            match assert_constraint env constr_exp with
            | Some nc ->
               typ_print ("Adding constraint " ^ string_of_n_constraint nc ^ " for assert");
               Env.add_constraint nc env
            | None -> env
          end
       | _ -> env in
     let inferred_body = irule infer_exp env body in
     annot_exp (E_internal_plet (tpat, bind_exp, inferred_body)) (typ_of inferred_body)
  | E_let (LB_aux (letbind, (let_loc, _)), exp) ->
     let bind_exp, pat, ptyp = match letbind with
       | LB_val (P_aux (P_typ (ptyp, _), _) as pat, bind) ->
          Env.wf_typ env ptyp;
          let checked_bind = crule check_exp env bind ptyp in
          checked_bind, pat, ptyp
       | LB_val (pat, bind) ->
          let inferred_bind = irule infer_exp env bind in
          inferred_bind, pat, typ_of inferred_bind in
     let tpat, env = bind_pat_no_guard env pat ptyp in
     let inferred_exp = irule infer_exp env exp in
     annot_exp (E_let (LB_aux (LB_val (tpat, bind_exp), (let_loc, None)), inferred_exp)) (typ_of inferred_exp)
  | E_ref id when Env.is_mutable id env ->
     let (_, typ) = Bindings.find id (Env.get_locals env) in
     annot_exp (E_ref id) (ref_typ typ)
  | E_ref id when Env.is_register id env ->
     let typ = Env.get_register id env in
     annot_exp (E_ref id) (register_typ typ)
  | _ -> typ_error l ("Cannot infer type of: " ^ string_of_exp exp)

and infer_funapp l env f xs ret_ctx_typ = fst (infer_funapp' l env f (Env.get_val_spec f env) xs ret_ctx_typ)

and instantiation_of (E_aux (exp_aux, (l, _)) as exp) =
  let env = env_of exp in
  match exp_aux with
  | E_app (f, xs) -> snd (infer_funapp' l (Env.no_casts env) f (Env.get_val_spec f env) (List.map strip_exp xs) (Some (typ_of exp)))
  | _ -> invalid_arg ("instantiation_of expected application,  got " ^ string_of_exp exp)

and infer_funapp' l env f (typq, f_typ) xs ret_ctx_typ =
  let annot_exp exp typ eff = E_aux (exp, (l, Some (env, Env.canonicalize env typ, eff))) in
  let switch_annot env typ = function
    | (E_aux (exp, (l, Some (_, _, eff)))) -> E_aux (exp, (l, Some (env, typ, eff)))
    | _ -> failwith "Cannot switch annot for unannotated function"
  in
  let all_unifiers = ref KBindings.empty in
  let ex_goal = ref None in
  let prove_goal env = match !ex_goal with
    | Some goal when prove env goal -> ()
    | Some goal -> typ_error l ("Could not prove existential goal: " ^ string_of_n_constraint goal)
    | None -> ()
  in
  let universals = Env.get_typ_vars env in
  let universal_constraints = Env.get_constraints env in
  let is_bound kid env = KBindings.mem kid (Env.get_typ_vars env) in
  let rec number n = function
    | [] -> []
    | (x :: xs) -> (n, x) :: number (n + 1) xs
  in
  let solve_quant env = function
    | QI_aux (QI_id _, _) -> false
    | QI_aux (QI_const nc, _) -> prove env nc
  in
  let rec instantiate env quants typs ret_typ args =
    match typs, args with
    | (utyps, []), (uargs, []) ->
       begin
         typ_debug ("Got unresolved args: " ^ string_of_list ", " (fun (_, exp) -> string_of_exp exp) uargs);
         if List.for_all (solve_quant env) quants
         then
           let iuargs = List.map2 (fun utyp (n, uarg) -> (n, crule check_exp env uarg utyp)) utyps uargs in
           (iuargs, ret_typ, env)
         else typ_raise l (Err_unresolved_quants (f, typq, quants, Env.get_typ_var_locs env, Env.get_constraints env))
       end
    | (utyps, (typ :: typs)), (uargs, ((n, arg) :: args))
         when List.for_all (fun kid -> is_bound kid env) (KidSet.elements (typ_frees typ)) ->
       begin
         let carg = crule check_exp env arg typ in
         let (iargs, ret_typ', env) = instantiate env quants (utyps, typs) ret_typ (uargs, args) in
         ((n, carg) :: iargs, ret_typ', env)
       end
    | (utyps, (typ :: typs)), (uargs, ((n, arg) :: args)) ->
       begin
         typ_debug ("INSTANTIATE: " ^ string_of_exp arg ^ " with " ^ string_of_typ typ);
         let iarg = irule infer_exp env arg in
         typ_debug ("INFER: " ^ string_of_exp arg ^ " type " ^ string_of_typ (typ_of iarg));
         try
           (* If we get an existential when instantiating, we prepend
              the identifier of the exisitential with the tag argN# to
              denote that it was bound by the Nth argument to the
              function. *)
           let ex_tag = "arg" ^ string_of_int n ^ "#" in
           let iarg, (unifiers, ex_kids, ex_nc) = type_coercion_unify env iarg typ in
           typ_debug (string_of_list ", " (fun (kid, uvar) -> string_of_kid kid ^ " => " ^ string_of_uvar uvar) (KBindings.bindings unifiers));
           typ_debug ("EX KIDS: " ^ string_of_list ", " string_of_kid ex_kids);
           let env = match ex_kids, ex_nc with
             | [], None -> env
             | _, Some enc ->
                let enc = List.fold_left (fun nc kid -> nc_subst_nexp kid (Nexp_var (prepend_kid ex_tag kid)) nc) enc ex_kids in
                let env = List.fold_left (fun env kid -> Env.add_typ_var l (prepend_kid ex_tag kid) BK_nat env) env ex_kids in
                Env.add_constraint enc env
             | _, None -> assert false (* Cannot have ex_kids without ex_nc *)
           in
           let tag_unifier uvar = List.fold_left (fun uvar kid -> uvar_subst_nexp kid (Nexp_var (prepend_kid ex_tag kid)) uvar) uvar ex_kids in
           let unifiers = KBindings.map tag_unifier unifiers in
           all_unifiers := merge_uvars l !all_unifiers unifiers;
           let utyps' = List.map (subst_unifiers unifiers) utyps in
           let typs' = List.map (subst_unifiers unifiers) typs in
           let quants' = List.fold_left (fun qs (kid, uvar) -> instantiate_quants qs kid uvar) quants (KBindings.bindings unifiers) in
           let ret_typ' = subst_unifiers unifiers ret_typ in
           let (iargs, ret_typ'', env) = instantiate env quants' (utyps', typs') ret_typ' (uargs, args) in
           ((n, iarg) :: iargs, ret_typ'', env)
         with
         | Unification_error (l, str) ->
            typ_print ("Unification error: " ^ str);
            instantiate env quants (typ :: utyps, typs) ret_typ ((n, arg) :: uargs, args)
       end
    | (_, []), _ -> typ_error l ("Function " ^ string_of_id f ^ " applied to too many arguments")
    | _, (_, []) -> typ_error l ("Function " ^ string_of_id f ^ " not applied to enough arguments")
  in
  let instantiate_ret env quants typs ret_typ =
    match ret_ctx_typ with
    | None -> (quants, typs, ret_typ, env)
    | Some rct when is_exist (Env.expand_synonyms env rct) -> (quants, typs, ret_typ, env)
    | Some rct ->
       begin
         typ_debug ("RCT is " ^ string_of_typ rct);
         typ_debug ("INSTANTIATE RETURN:" ^ string_of_typ ret_typ);
         let unifiers, ex_kids, ex_nc =
           try unify l env ret_typ rct with
           | Unification_error _ -> typ_debug "UERROR"; KBindings.empty, [], None
         in
         typ_debug (string_of_list ", " (fun (kid, uvar) -> string_of_kid kid ^ " => " ^ string_of_uvar uvar) (KBindings.bindings unifiers));
         if ex_kids = [] then () else (typ_debug ("EX GOAL: " ^ string_of_option string_of_n_constraint ex_nc); ex_goal := ex_nc);
         all_unifiers := merge_uvars l !all_unifiers unifiers;
         let env = List.fold_left (fun env kid -> Env.add_typ_var l kid BK_nat env) env ex_kids in
         let typs' = List.map (subst_unifiers unifiers) typs in
         let quants' = List.fold_left (fun qs (kid, uvar) -> instantiate_quants qs kid uvar) quants (KBindings.bindings unifiers) in
         let ret_typ' =
           match ex_nc with
           | None -> subst_unifiers unifiers ret_typ
           | Some nc -> mk_typ (Typ_exist (ex_kids, nc, subst_unifiers unifiers ret_typ))
         in
         (quants', typs', ret_typ', env)
       end
  in
  let (quants, typ_args, typ_ret, env), eff =
    match Env.expand_synonyms env f_typ with
    | Typ_aux (Typ_fn (Typ_aux (Typ_tup typ_args, _), typ_ret, eff), _) ->
       instantiate_ret env (quant_items typq) typ_args typ_ret, eff
    | Typ_aux (Typ_fn (typ_arg, typ_ret, eff), _) ->
       instantiate_ret env (quant_items typq) [typ_arg] typ_ret, eff
    | _ -> typ_error l (string_of_typ f_typ ^ " is not a function type")
  in
  let (xs_instantiated, typ_ret, env) = instantiate env quants ([], typ_args) typ_ret ([], number 0 xs) in
  let xs_reordered = List.map snd (List.sort (fun (n, _) (m, _) -> compare n m) xs_instantiated) in

  prove_goal env;

  let ty_vars = List.map fst (KBindings.bindings (Env.get_typ_vars env)) in
  let existentials = List.filter (fun kid -> not (KBindings.mem kid universals)) ty_vars in
  let num_new_ncs = List.length (Env.get_constraints env) - List.length universal_constraints in
  let ex_constraints = take num_new_ncs (Env.get_constraints env) in

  typ_debug ("Existentials: " ^ string_of_list ", " string_of_kid existentials);
  typ_debug ("Existential constraints: " ^ string_of_list ", " string_of_n_constraint ex_constraints);

  let typ_ret =
    if KidSet.is_empty (KidSet.of_list existentials) || KidSet.is_empty (typ_frees typ_ret)
    then (typ_debug "Returning Existential"; typ_ret)
    else mk_typ (Typ_exist (existentials, List.fold_left nc_and nc_true ex_constraints, typ_ret))
  in
  let typ_ret = flatten_existential typ_ret in
  let exp = annot_exp (E_app (f, xs_reordered)) typ_ret eff in
  typ_debug ("RETURNING: " ^ string_of_typ (typ_of exp));
  match ret_ctx_typ with
  | None ->
     exp, !all_unifiers
  | Some rct ->
     let exp = type_coercion env exp rct in
     typ_debug ("RETURNING AFTER COERCION " ^ string_of_typ (typ_of exp));
     exp, !all_unifiers

(**************************************************************************)
(* 6. Effect system                                                       *)
(**************************************************************************)

let effect_of_annot = function
| Some (_, _, eff) -> eff
| None -> no_effect

let effect_of (E_aux (exp, (l, annot))) = effect_of_annot annot

let add_effect_annot annot eff = match annot with
  | Some (env, typ, eff') -> Some (env, typ, union_effects eff eff')
  | None -> None

let add_effect (E_aux (exp, (l, annot))) eff =
  E_aux (exp, (l, add_effect_annot annot eff))

let effect_of_lexp (LEXP_aux (exp, (l, annot))) = effect_of_annot annot

let add_effect_lexp (LEXP_aux (lexp, (l, annot))) eff =
  LEXP_aux (lexp, (l, add_effect_annot annot eff))

let effect_of_pat (P_aux (exp, (l, annot))) = effect_of_annot annot

let add_effect_pat (P_aux (pat, (l, annot))) eff =
  P_aux (pat, (l, add_effect_annot annot eff))

let collect_effects xs = List.fold_left union_effects no_effect (List.map effect_of xs)

let collect_effects_lexp xs = List.fold_left union_effects no_effect (List.map effect_of_lexp xs)

let collect_effects_pat xs = List.fold_left union_effects no_effect (List.map effect_of_pat xs)

(* Traversal that propagates effects upwards through expressions *)

let rec propagate_exp_effect (E_aux (exp, annot)) =
  let p_exp, eff = propagate_exp_effect_aux exp in
  add_effect (E_aux (p_exp, annot)) eff
and propagate_exp_effect_aux = function
  | E_block xs ->
     let p_xs = List.map propagate_exp_effect xs in
     E_block p_xs, collect_effects p_xs
  | E_nondet xs ->
     let p_xs = List.map propagate_exp_effect xs in
     E_nondet p_xs, collect_effects p_xs
  | E_id id -> E_id id, no_effect
  | E_ref id -> E_ref id, no_effect
  | E_lit lit -> E_lit lit, no_effect
  | E_cast (typ, exp) ->
     let p_exp = propagate_exp_effect exp in
     E_cast (typ, p_exp), effect_of p_exp
  | E_app (id, xs) ->
     let p_xs = List.map propagate_exp_effect xs in
     E_app (id, p_xs), collect_effects p_xs
  | E_vector xs ->
     let p_xs = List.map propagate_exp_effect xs in
     E_vector p_xs, collect_effects p_xs
  | E_vector_access (v, i) ->
     let p_v = propagate_exp_effect v in
     let p_i = propagate_exp_effect i in
     E_vector_access (p_v, p_i), collect_effects [p_v; p_i]
  | E_vector_subrange (v, i, j) ->
     let p_v = propagate_exp_effect v in
     let p_i = propagate_exp_effect i in
     let p_j = propagate_exp_effect j in
     E_vector_subrange (p_v, p_i, p_j), collect_effects [p_v; p_i; p_j]
  | E_vector_update (v, i, x) ->
     let p_v = propagate_exp_effect v in
     let p_i = propagate_exp_effect i in
     let p_x = propagate_exp_effect x in
     E_vector_update (p_v, p_i, p_x), collect_effects [p_v; p_i; p_x]
  | E_vector_update_subrange (v, i, j, v') ->
     let p_v = propagate_exp_effect v in
     let p_i = propagate_exp_effect i in
     let p_j = propagate_exp_effect j in
     let p_v' = propagate_exp_effect v' in
     E_vector_update_subrange (p_v, p_i, p_j, p_v'), collect_effects [p_v; p_i; p_j; p_v']
  | E_vector_append (v1, v2) ->
     let p_v1 = propagate_exp_effect v1 in
     let p_v2 = propagate_exp_effect v2 in
     E_vector_append (p_v1, p_v2), collect_effects [p_v1; p_v2]
  | E_tuple xs ->
     let p_xs = List.map propagate_exp_effect xs in
     E_tuple p_xs, collect_effects p_xs
  | E_if (cond, t, e) ->
     let p_cond = propagate_exp_effect cond in
     let p_t = propagate_exp_effect t in
     let p_e =  propagate_exp_effect e in
     E_if (p_cond, p_t, p_e), collect_effects [p_cond; p_t; p_e]
  | E_case (exp, cases) ->
     let p_exp = propagate_exp_effect exp in
     let p_cases = List.map propagate_pexp_effect cases in
     let case_eff = List.fold_left union_effects no_effect (List.map snd p_cases) in
     E_case (p_exp, List.map fst p_cases), union_effects (effect_of p_exp) case_eff
  | E_record_update (exp, FES_aux (FES_Fexps (fexps, flag), (l, _))) ->
     let p_exp = propagate_exp_effect exp in
     let p_fexps = List.map propagate_fexp_effect fexps in
     E_record_update (p_exp, FES_aux (FES_Fexps (List.map fst p_fexps, flag), (l, None))),
     List.fold_left union_effects no_effect (effect_of p_exp :: List.map snd p_fexps)
  | E_record (FES_aux (FES_Fexps (fexps, flag), (l, _))) ->
     let p_fexps = List.map propagate_fexp_effect fexps in
     E_record (FES_aux (FES_Fexps (List.map fst p_fexps, flag), (l, None))),
     List.fold_left union_effects no_effect (List.map snd p_fexps)
  | E_try (exp, cases) ->
     let p_exp = propagate_exp_effect exp in
     let p_cases = List.map propagate_pexp_effect cases in
     let case_eff = List.fold_left union_effects no_effect (List.map snd p_cases) in
     E_try (p_exp, List.map fst p_cases), union_effects (effect_of p_exp) case_eff
  | E_for (v, f, t, step, ord, body) ->
     let p_f = propagate_exp_effect f in
     let p_t = propagate_exp_effect t in
     let p_step = propagate_exp_effect step in
     let p_body = propagate_exp_effect body in
     E_for (v, p_f, p_t, p_step, ord, p_body),
     collect_effects [p_f; p_t; p_step; p_body]
  | E_loop (loop_type, cond, body) ->
     let p_cond = propagate_exp_effect cond in
     let p_body = propagate_exp_effect body in
     E_loop (loop_type, p_cond, p_body),
     union_effects (effect_of p_cond) (effect_of p_body)
  | E_let (letbind, exp) ->
     let p_lb, eff = propagate_letbind_effect letbind in
     let p_exp = propagate_exp_effect exp in
     E_let (p_lb, p_exp), union_effects (effect_of p_exp) eff
  | E_cons (x, xs) ->
     let p_x = propagate_exp_effect x in
     let p_xs = propagate_exp_effect xs in
     E_cons (p_x, p_xs), union_effects (effect_of p_x) (effect_of p_xs)
  | E_list xs ->
     let p_xs = List.map propagate_exp_effect xs in
     E_list p_xs, collect_effects p_xs
  | E_assign (lexp, exp) ->
     let p_lexp = propagate_lexp_effect lexp in
     let p_exp = propagate_exp_effect exp in
     E_assign (p_lexp, p_exp), union_effects (effect_of p_exp) (effect_of_lexp p_lexp)
  | E_var (lexp, bind, exp) ->
     let p_lexp = propagate_lexp_effect lexp in
     let p_bind = propagate_exp_effect bind in
     let p_exp = propagate_exp_effect exp in
     E_var (p_lexp, p_bind, p_exp), union_effects (effect_of_lexp p_lexp) (collect_effects [p_bind; p_exp])
  | E_sizeof nexp -> E_sizeof nexp, no_effect
  | E_constraint nc -> E_constraint nc, no_effect
  | E_exit exp ->
     let p_exp = propagate_exp_effect exp in
     E_exit p_exp, effect_of p_exp
  | E_throw exp ->
     let p_exp = propagate_exp_effect exp in
     E_throw p_exp, effect_of p_exp
  | E_return exp ->
     let p_exp = propagate_exp_effect exp in
     E_return p_exp, effect_of p_exp
  | E_assert (test, msg) ->
     let p_test = propagate_exp_effect test in
     let p_msg = propagate_exp_effect msg in
     E_assert (p_test, p_msg), collect_effects [p_test; p_msg]
  | E_field (exp, id) ->
     let p_exp = propagate_exp_effect exp in
     E_field (p_exp, id), effect_of p_exp
  | E_internal_plet (pat, exp, body) ->
     let p_pat = propagate_pat_effect pat in
     let p_exp = propagate_exp_effect exp in
     let p_body = propagate_exp_effect body in
     E_internal_plet (p_pat, p_exp, p_body),
     union_effects (effect_of_pat p_pat) (collect_effects [p_exp; p_body])
  | E_internal_return exp ->
     let p_exp = propagate_exp_effect exp in
     E_internal_return p_exp, effect_of p_exp
  | exp_aux -> typ_error Parse_ast.Unknown ("Unimplemented: Cannot propagate effect in expression "
                                            ^ string_of_exp (E_aux (exp_aux, (Parse_ast.Unknown, None))))

and propagate_fexp_effect (FE_aux (FE_Fexp (id, exp), (l, _))) =
  let p_exp = propagate_exp_effect exp in
  FE_aux (FE_Fexp (id, p_exp), (l, None)), effect_of p_exp

and propagate_pexp_effect = function
  | Pat_aux (Pat_exp (pat, exp), (l, annot)) ->
     begin
       let p_pat = propagate_pat_effect pat in
       let p_exp = propagate_exp_effect exp in
       let p_eff = union_effects (effect_of_pat p_pat) (effect_of p_exp) in
       match annot with
       | Some (typq, typ, eff) ->
          Pat_aux (Pat_exp (p_pat, p_exp), (l, Some (typq, typ, union_effects eff p_eff))),
         union_effects eff p_eff
       | None -> Pat_aux (Pat_exp (p_pat, p_exp), (l, None)), p_eff
     end
  | Pat_aux (Pat_when (pat, guard, exp), (l, annot)) ->
     begin
       let p_pat = propagate_pat_effect pat in
       let p_guard = propagate_exp_effect guard in
       let p_exp = propagate_exp_effect exp in
       let p_eff = union_effects (effect_of_pat p_pat)
                                          (union_effects (effect_of p_guard) (effect_of p_exp))
       in
       match annot with
       | Some (typq, typ, eff) ->
          Pat_aux (Pat_when (p_pat, p_guard, p_exp), (l, Some (typq, typ, union_effects eff p_eff))),
          union_effects eff p_eff
       | None -> Pat_aux (Pat_when (p_pat, p_guard, p_exp), (l, None)), p_eff
     end

and propagate_pat_effect (P_aux (pat, annot)) =
  let p_pat, eff = propagate_pat_effect_aux pat in
  add_effect_pat (P_aux (p_pat, annot)) eff
and propagate_pat_effect_aux = function
  | P_lit lit -> P_lit lit, no_effect
  | P_wild -> P_wild, no_effect
  | P_cons (pat1, pat2) ->
     let p_pat1 = propagate_pat_effect pat1 in
     let p_pat2 = propagate_pat_effect pat2 in
     P_cons (p_pat1, p_pat2), union_effects (effect_of_pat p_pat1) (effect_of_pat p_pat2)
  | P_as (pat, id) ->
     let p_pat = propagate_pat_effect pat in
     P_as (p_pat, id), effect_of_pat p_pat
  | P_typ (typ, pat) ->
     let p_pat = propagate_pat_effect pat in
     P_typ (typ, p_pat), effect_of_pat p_pat
  | P_id id -> P_id id, no_effect
  | P_var (pat, kid) ->
     let p_pat = propagate_pat_effect pat in
     P_var (p_pat, kid), effect_of_pat p_pat
  | P_app (id, pats) ->
     let p_pats = List.map propagate_pat_effect pats in
     P_app (id, p_pats), collect_effects_pat p_pats
  | P_tup pats ->
     let p_pats = List.map propagate_pat_effect pats in
     P_tup p_pats, collect_effects_pat p_pats
  | P_list pats ->
     let p_pats = List.map propagate_pat_effect pats in
     P_list p_pats, collect_effects_pat p_pats
  | P_vector_concat pats ->
     let p_pats = List.map propagate_pat_effect pats in
     P_vector_concat p_pats, collect_effects_pat p_pats
  | P_vector pats ->
     let p_pats = List.map propagate_pat_effect pats in
     P_vector p_pats, collect_effects_pat p_pats
  | _ -> typ_error Parse_ast.Unknown "Unimplemented: Cannot propagate effect in pat"

and propagate_letbind_effect (LB_aux (lb, (l, annot))) =
  let p_lb, eff = propagate_letbind_effect_aux lb in
  match annot with
  | Some (typq, typ, eff) -> LB_aux (p_lb, (l, Some (typq, typ, eff))), eff
  | None -> LB_aux (p_lb, (l, None)), eff
and propagate_letbind_effect_aux = function
  | LB_val (pat, exp) ->
     let p_pat = propagate_pat_effect pat in
     let p_exp = propagate_exp_effect exp in
     LB_val (p_pat, p_exp),
     union_effects (effect_of_pat p_pat) (effect_of p_exp)

and propagate_lexp_effect (LEXP_aux (lexp, annot)) =
  let p_lexp, eff = propagate_lexp_effect_aux lexp in
  add_effect_lexp (LEXP_aux (p_lexp, annot)) eff
and propagate_lexp_effect_aux = function
  | LEXP_id id -> LEXP_id id, no_effect
  | LEXP_deref exp ->
     let p_exp = propagate_exp_effect exp in
     LEXP_deref p_exp, effect_of p_exp
  | LEXP_memory (id, exps) ->
     let p_exps = List.map propagate_exp_effect exps in
     LEXP_memory (id, p_exps), collect_effects p_exps
  | LEXP_cast (typ, id) -> LEXP_cast (typ, id), no_effect
  | LEXP_tup lexps ->
     let p_lexps = List.map propagate_lexp_effect lexps in
     LEXP_tup p_lexps, collect_effects_lexp p_lexps
  | LEXP_vector (lexp, exp) ->
     let p_lexp = propagate_lexp_effect lexp in
     let p_exp = propagate_exp_effect exp in
     LEXP_vector (p_lexp, p_exp), union_effects (effect_of p_exp) (effect_of_lexp p_lexp)
  | LEXP_vector_range (lexp, exp1, exp2) ->
     let p_lexp = propagate_lexp_effect lexp in
     let p_exp1 = propagate_exp_effect exp1 in
     let p_exp2 = propagate_exp_effect exp2 in
     LEXP_vector_range (p_lexp, p_exp1, p_exp2),
     union_effects (collect_effects [p_exp1; p_exp2]) (effect_of_lexp p_lexp)
  | LEXP_field (lexp, id) ->
     let p_lexp = propagate_lexp_effect lexp in
     LEXP_field (p_lexp, id),effect_of_lexp p_lexp

(**************************************************************************)
(* 6. Checking toplevel definitions                                       *)
(**************************************************************************)

let check_letdef orig_env (LB_aux (letbind, (l, _))) =
  typ_print "\nChecking top-level let";
  begin
    match letbind with
    | LB_val (P_aux (P_typ (typ_annot, pat), _), bind) ->
       let checked_bind = crule check_exp orig_env (strip_exp bind) typ_annot in
       let tpat, env = bind_pat_no_guard orig_env (strip_pat pat) typ_annot in
       [DEF_val (LB_aux (LB_val (P_aux (P_typ (typ_annot, tpat), (l, Some (orig_env, typ_annot, no_effect))), checked_bind), (l, None)))], env
    | LB_val (pat, bind) ->
       let inferred_bind = irule infer_exp orig_env (strip_exp bind) in
       let tpat, env = bind_pat_no_guard orig_env (strip_pat pat) (typ_of inferred_bind) in
       [DEF_val (LB_aux (LB_val (tpat, inferred_bind), (l, None)))], env
  end

let check_funcl env (FCL_aux (FCL_Funcl (id, pexp), (l, _))) typ =
  match typ with
  | Typ_aux (Typ_fn (typ_arg, typ_ret, eff), _) ->
     begin
       let env = Env.add_ret_typ typ_ret env in
       (* We want to forbid polymorphic undefined values in all cases,
          except when type checking the specific undefined_(type)
          functions created by the -undefined_gen functions in
          initial_check.ml. Only in these functions will the rewriter
          be able to correctly re-write the polymorphic undefineds
          (due to the specific form the functions have *)
       let env =
         if Str.string_match (Str.regexp_string "undefined_") (string_of_id id) 0
         then Env.allow_polymorphic_undefineds env
         else env
       in
       let typed_pexp, prop_eff = propagate_pexp_effect (check_case env typ_arg (strip_pexp pexp) typ_ret) in
       FCL_aux (FCL_Funcl (id, typed_pexp), (l, Some (env, typ, prop_eff)))
     end
  | _ -> typ_error l ("Function clause must have function type: " ^ string_of_typ typ ^ " is not a function type")

let funcl_effect (FCL_aux (FCL_Funcl (id, typed_pexp), (l, annot))) =
  match annot with
  | Some (_, _, eff) -> eff
  | None -> no_effect (* Maybe could be assert false. This should never happen *)

let infer_funtyp l env tannotopt funcls =
  match tannotopt with
  | Typ_annot_opt_aux (Typ_annot_opt_some (quant, ret_typ), _) ->
     begin
       let rec typ_from_pat (P_aux (pat_aux, (l, _)) as pat) =
         match pat_aux with
         | P_lit lit -> infer_lit env lit
         | P_typ (typ, _) -> typ
         | P_tup pats -> mk_typ (Typ_tup (List.map typ_from_pat pats))
         | _ -> typ_error l ("Cannot infer type from pattern " ^ string_of_pat pat)
       in
       match funcls with
       | [FCL_aux (FCL_Funcl (_, Pat_aux (pexp,_)), _)] ->
          let pat = match pexp with Pat_exp (pat,_) | Pat_when (pat,_,_) -> pat in
          let arg_typ = typ_from_pat pat in
          let fn_typ = mk_typ (Typ_fn (arg_typ, ret_typ, Effect_aux (Effect_set [], Parse_ast.Unknown))) in
          (quant, fn_typ)
       | _ -> typ_error l "Cannot infer function type for function with multiple clauses"
     end
  | Typ_annot_opt_aux (Typ_annot_opt_none, _) -> typ_error l "Cannot infer function type for unannotated function"

let mk_val_spec typq typ id = DEF_spec (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (typq, typ), Parse_ast.Unknown), id, (fun _ -> None), false), (Parse_ast.Unknown, None)))

let check_tannotopt env typq ret_typ = function
  | Typ_annot_opt_aux (Typ_annot_opt_none, _) -> ()
  | Typ_annot_opt_aux (Typ_annot_opt_some (annot_typq, annot_ret_typ), l) ->
     if typ_identical env ret_typ annot_ret_typ
     then ()
     else typ_error l (string_of_bind (typq, ret_typ) ^ " and " ^ string_of_bind (annot_typq, annot_ret_typ) ^ " do not match between function and val spec")

let check_fundef env (FD_aux (FD_function (recopt, tannotopt, effectopt, funcls), (l, _)) as fd_aux) =
  let id =
    match (List.fold_right
             (fun (FCL_aux (FCL_Funcl (id, _), _)) id' ->
               match id' with
               | Some id' -> if string_of_id id' = string_of_id id then Some id'
                             else typ_error l ("Function declaration expects all definitions to have the same name, "
                                               ^ string_of_id id ^ " differs from other definitions of " ^ string_of_id id')
               | None -> Some id) funcls None)
    with
    | Some id -> id
    | None -> typ_error l "funcl list is empty"
  in
  typ_print ("\nChecking function " ^ string_of_id id);
  let have_val_spec, (quant, typ), env =
    try true, Env.get_val_spec id env, env with
    | Type_error (l, _) ->
       let (quant, typ) = infer_funtyp l env tannotopt funcls in
       false, (quant, typ), env
  in
  let vtyp_arg, vtyp_ret, declared_eff, vl = match typ with
    | Typ_aux (Typ_fn (vtyp_arg, vtyp_ret, declared_eff), vl) -> vtyp_arg, vtyp_ret, declared_eff, vl
    | _ -> typ_error l "Function val spec was not a function type"
  in
  check_tannotopt env quant vtyp_ret tannotopt;
  typ_debug ("Checking fundef " ^ string_of_id id ^ " has type " ^ string_of_bind (quant, typ));
  let funcl_env = add_typquant l quant env in
  let funcls = List.map (fun funcl -> check_funcl funcl_env funcl typ) funcls in
  let eff = List.fold_left union_effects no_effect (List.map funcl_effect funcls) in
  let vs_def, env, declared_eff =
    if not have_val_spec
    then
      let typ = Typ_aux (Typ_fn (vtyp_arg, vtyp_ret, eff), vl) in
      [mk_val_spec quant typ id], Env.add_val_spec id (quant, Env.canonicalize env typ) env, eff
    else [], env, declared_eff
  in
  let env = Env.define_val_spec id env in
  if (equal_effects eff declared_eff || !opt_no_effects)
  then
    vs_def @ [DEF_fundef (FD_aux (FD_function (recopt, tannotopt, effectopt, funcls), (l, None)))], env
  else typ_error l ("Effects do not match: " ^ string_of_effect declared_eff ^ " declared and " ^ string_of_effect eff ^ " found")

(* Checking a val spec simply adds the type as a binding in the
   context. We have to destructure the various kinds of val specs, but
   the difference is irrelevant for the typechecker. *)
let check_val_spec env (VS_aux (vs, (l, _))) =
  let (id, quants, typ, env) = match vs with
    | VS_val_spec (TypSchm_aux (TypSchm_ts (quants, typ), _) as typschm, id, ext_opt, is_cast) ->
       typ_debug ("VS typschm: " ^ string_of_id id ^ ", " ^ string_of_typschm typschm);
       let env = match (ext_opt "smt", ext_opt "#") with
         | Some op, None -> Env.add_smt_op id op env
         | _, _ -> env
       in
       Env.wf_typ (add_typquant l quants env) typ;
       typ_debug "CHECKED WELL-FORMED VAL SPEC";
       let env =
       (* match ext_opt with
         | None -> env
         | Some ext -> *)
         Env.add_extern id ext_opt env
       in
       let env = if is_cast then Env.add_cast id env else env in
       (id, quants, typ, env)
  in
  [DEF_spec (VS_aux (vs, (l, None)))], Env.add_val_spec id (quants, Env.canonicalize env (Env.expand_synonyms (add_typquant l quants env) typ)) env

let check_default env (DT_aux (ds, l)) =
  match ds with
  | DT_kind _ -> [DEF_default (DT_aux (ds,l))], env (* Check: Is this supposed to do nothing? *)
  | DT_order (Ord_aux (Ord_inc, _)) -> [DEF_default (DT_aux (ds, l))], Env.set_default_order_inc env
  | DT_order (Ord_aux (Ord_dec, _)) -> [DEF_default (DT_aux (ds, l))], Env.set_default_order_dec env
  | DT_order (Ord_aux (Ord_var _, _)) -> typ_error l "Cannot have variable default order"
  (* This branch allows us to write something like: default forall Nat 'n. [|'n|] name... what does this even mean?! *)
  | DT_typ (typschm, id) -> typ_error l ("Unsupported default construct")

let kinded_id_arg kind_id =
  let typ_arg arg = Typ_arg_aux (arg, Parse_ast.Unknown) in
  match kind_id with
  | KOpt_aux (KOpt_none kid, _) -> typ_arg (Typ_arg_nexp (nvar kid))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_nat, _)], _), kid), _) -> typ_arg (Typ_arg_nexp (nvar kid))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_order, _)], _), kid), _) ->
     typ_arg (Typ_arg_order (Ord_aux (Ord_var kid, Parse_ast.Unknown)))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_type, _)], _), kid), _) ->
     typ_arg (Typ_arg_typ (mk_typ (Typ_var kid)))
  | KOpt_aux (KOpt_kind (K_aux (K_kind kinds, _), kid), l) -> typ_error l "Badly formed kind"

let fold_union_quant quants (QI_aux (qi, l)) =
  match qi with
  | QI_id kind_id -> quants @ [kinded_id_arg kind_id]
  | _ -> quants

let check_type_union env variant typq (Tu_aux (tu, l)) =
  let ret_typ = app_typ variant (List.fold_left fold_union_quant [] (quant_items typq)) in
  match tu with
  | Tu_ty_id (typ, v) ->
     let typ' = mk_typ (Typ_fn (typ, ret_typ, no_effect)) in
     env
     |> Env.add_union_id v (typq, typ')
     |> Env.add_val_spec v (typq, typ')

(* FIXME: This code is duplicated with general kind-checking code in environment, can they be merged? *)
let mk_synonym typq typ =
  let kopts, ncs = quant_split typq in
  let rec subst_args kopts args =
    match kopts, args with
    | kopt :: kopts, Typ_arg_aux (Typ_arg_nexp arg, _) :: args when is_nat_kopt kopt ->
       let typ, ncs = subst_args kopts args in
       typ_subst_nexp (kopt_kid kopt) (unaux_nexp arg) typ,
       List.map (nc_subst_nexp (kopt_kid kopt) (unaux_nexp arg)) ncs
    | kopt :: kopts, Typ_arg_aux (Typ_arg_typ arg, _) :: args when is_typ_kopt kopt ->
       let typ, ncs = subst_args kopts args in
       typ_subst_typ (kopt_kid kopt) (unaux_typ arg) typ, ncs
    | kopt :: kopts, Typ_arg_aux (Typ_arg_order arg, _) :: args when is_order_kopt kopt ->
       let typ, ncs = subst_args kopts args in
       typ_subst_order (kopt_kid kopt) (unaux_order arg) typ, ncs
    | [], [] -> typ, ncs
    | _, Typ_arg_aux (_, l) :: _ -> typ_error l "Synonym applied to bad arguments"
    | _, _ -> typ_error Parse_ast.Unknown "Synonym applied to bad arguments"
  in
  fun env args ->
    let typ, ncs = subst_args kopts args in
    if List.for_all (prove env) ncs
    then typ
    else typ_error Parse_ast.Unknown ("Could not prove constraints " ^ string_of_list ", " string_of_n_constraint ncs
                                      ^ " in type synonym " ^ string_of_typ typ
                                      ^ " with " ^ string_of_list ", " string_of_n_constraint (Env.get_constraints env))

let check_kinddef env (KD_aux (kdef, (l, _))) =
  let kd_err () = raise (Reporting_basic.err_unreachable Parse_ast.Unknown "Unimplemented kind def") in
  match kdef with
  | KD_nabbrev ((K_aux(K_kind([BK_aux (BK_nat, _)]),_) as kind), id, nmscm, nexp) ->
     [DEF_kind (KD_aux (KD_nabbrev (kind, id, nmscm, nexp), (l, None)))],
     Env.add_num_def id nexp env
  | _ -> kd_err ()

let rec check_typedef : 'a. Env.t -> 'a type_def -> (tannot def) list * Env.t =
  fun env (TD_aux (tdef, (l, _))) ->
  let td_err () = raise (Reporting_basic.err_unreachable Parse_ast.Unknown "Unimplemented Typedef") in
  match tdef with
  | TD_abbrev (id, nmscm, (TypSchm_aux (TypSchm_ts (typq, typ), _))) ->
     [DEF_type (TD_aux (tdef, (l, None)))], Env.add_typ_synonym id (mk_synonym typq typ) env
  | TD_record (id, nmscm, typq, fields, _) ->
     [DEF_type (TD_aux (tdef, (l, None)))], Env.add_record id typq fields env
  | TD_variant (id, nmscm, typq, arms, _) ->
     let env =
       env
       |> Env.add_variant id (typq, arms)
       |> (fun env -> List.fold_left (fun env tu -> check_type_union env id typq tu) env arms)
     in
     [DEF_type (TD_aux (tdef, (l, None)))], env
  | TD_enum (id, nmscm, ids, _) ->
     [DEF_type (TD_aux (tdef, (l, None)))], Env.add_enum id ids env
  | TD_bitfield (id, typ, ranges) ->
     let typ = Env.expand_synonyms env typ in
     begin
       match typ with
       (* The type of a bitfield must be a constant-width bitvector *)
       | Typ_aux (Typ_app (v, [Typ_arg_aux (Typ_arg_nexp (Nexp_aux (Nexp_constant size, _)), _);
                               Typ_arg_aux (Typ_arg_order order, _);
                               Typ_arg_aux (Typ_arg_typ (Typ_aux (Typ_id b, _)), _)]), _)
            when string_of_id v = "vector" && string_of_id b = "bit" ->
          let size = Big_int.to_int size in
          let (Defs defs), env = check' env (Bitfield.macro id size order ranges) in
          defs, env
       | _ ->
          typ_error l "Bad bitfield type"
     end

and check_def : 'a. Env.t -> 'a def -> (tannot def) list * Env.t =
  fun env def ->
  let cd_err () = raise (Reporting_basic.err_unreachable Parse_ast.Unknown "Unimplemented Case") in
  match def with
  | DEF_kind kdef -> check_kinddef env kdef
  | DEF_type tdef -> check_typedef env tdef
  | DEF_fixity (prec, n, op) -> [DEF_fixity (prec, n, op)], env
  | DEF_fundef fdef -> check_fundef env fdef
  | DEF_internal_mutrec fdefs ->
     let defs = List.concat (List.map (fun fdef -> fst (check_fundef env fdef)) fdefs) in
     let split_fundef (defs, fdefs) def = match def with
       | DEF_fundef fdef -> (defs, fdefs @ [fdef])
       | _ -> (defs @ [def], fdefs) in
     let (defs, fdefs) = List.fold_left split_fundef ([], []) defs in
     (defs @ [DEF_internal_mutrec fdefs]), env
  | DEF_val letdef -> check_letdef env letdef
  | DEF_spec vs -> check_val_spec env vs
  | DEF_default default -> check_default env default
  | DEF_overload (id, ids) -> [DEF_overload (id, ids)], Env.add_overloads id ids env
  | DEF_reg_dec (DEC_aux (DEC_reg (typ, id), (l, _))) ->
     let env = Env.add_register id typ env in
     [DEF_reg_dec (DEC_aux (DEC_reg (typ, id), (l, Some (env, typ, no_effect))))], env
  | DEF_reg_dec (DEC_aux (DEC_alias (id, aspec), (l, annot))) -> cd_err ()
  | DEF_reg_dec (DEC_aux (DEC_typ_alias (typ, id, aspec), (l, tannot))) -> cd_err ()
  | DEF_scattered _ -> raise (Reporting_basic.err_unreachable Parse_ast.Unknown "Scattered given to type checker")
  | DEF_comm (DC_comm str) -> [DEF_comm (DC_comm str)], env
  | DEF_comm (DC_comm_struct def) ->
     let defs, env = check_def env def
     in List.map (fun def -> DEF_comm (DC_comm_struct def)) defs, env

and check' : 'a. Env.t -> 'a defs -> tannot defs * Env.t =
  fun env (Defs defs) ->
  match defs with
  | [] -> (Defs []), env
  | def :: defs ->
     let (def, env) = check_def env def in
     let (Defs defs, env) = check' env (Defs defs) in
     (Defs (def @ defs)), env

let check : 'a. Env.t -> 'a defs -> tannot defs * Env.t =
  fun env defs ->
  try check' env defs with
  | Type_error (l, err) -> raise (Reporting_basic.err_typ l (string_of_type_error err))

let initial_env =
  Env.empty
  |> Env.add_prover prove
  (* |> Env.add_typ_synonym (mk_id "atom") (fun _ args -> mk_typ (Typ_app (mk_id "range", args @ args))) *)

  (* Internal functions for Monomorphise.AtomToItself *)

  |> Env.add_extern (mk_id "size_itself_int") (fun _ -> Some "size_itself_int")
  |> Env.add_val_spec (mk_id "size_itself_int")
      (TypQ_aux (TypQ_tq [QI_aux (QI_id (KOpt_aux (KOpt_none (mk_kid "n"),Parse_ast.Unknown)),
                                  Parse_ast.Unknown)],Parse_ast.Unknown),
       function_typ (app_typ (mk_id "itself") [mk_typ_arg (Typ_arg_nexp (nvar (mk_kid "n")))])
         (atom_typ (nvar (mk_kid "n"))) no_effect)
  |> Env.add_extern (mk_id "make_the_value") (fun _ -> Some "make_the_value")
  |> Env.add_val_spec (mk_id "make_the_value")
      (TypQ_aux (TypQ_tq [QI_aux (QI_id (KOpt_aux (KOpt_none (mk_kid "n"),Parse_ast.Unknown)),
                                  Parse_ast.Unknown)],Parse_ast.Unknown),
       function_typ (atom_typ (nvar (mk_kid "n")))
         (app_typ (mk_id "itself") [mk_typ_arg (Typ_arg_nexp (nvar (mk_kid "n")))]) no_effect)

(*Generated by Lem from maybe.lem.*)
open HolKernel Parse boolLib bossLib;
open lem_boolTheory lem_basic_classesTheory lem_functionTheory;

val _ = numLib.prefer_num();



val _ = new_theory "lem_maybe"

 

(*open import Bool Basic_classes Function*)

(* ========================================================================== *)
(* Basic stuff                                                                *)
(* ========================================================================== *)

(*type maybe 'a = 
  | Nothing
  | Just of 'a*)


(*val maybeEqual : forall 'a. Eq 'a => maybe 'a -> maybe 'a -> bool*)
(*val maybeEqualBy : forall 'a. ('a -> 'a -> bool) -> maybe 'a -> maybe 'a -> bool*)

val _ = Define `
 ((maybeEqualBy:('a -> 'a -> bool) -> 'a option -> 'a option -> bool) eq NONE NONE=  T)
/\ ((maybeEqualBy:('a -> 'a -> bool) -> 'a option -> 'a option -> bool) eq NONE (SOME _)=  F)
/\ ((maybeEqualBy:('a -> 'a -> bool) -> 'a option -> 'a option -> bool) eq (SOME _) NONE=  F)
/\ ((maybeEqualBy:('a -> 'a -> bool) -> 'a option -> 'a option -> bool) eq (SOME x') (SOME y')=  (eq x' y'))`;
  


val _ = Define `
 ((maybeCompare:('b -> 'a -> lem_basic_classes$ordering) -> 'b option -> 'a option -> lem_basic_classes$ordering) cmp NONE NONE=  EQ)
/\ ((maybeCompare:('b -> 'a -> lem_basic_classes$ordering) -> 'b option -> 'a option -> lem_basic_classes$ordering) cmp NONE (SOME _)=  LT)
/\ ((maybeCompare:('b -> 'a -> lem_basic_classes$ordering) -> 'b option -> 'a option -> lem_basic_classes$ordering) cmp (SOME _) NONE=  GT)
/\ ((maybeCompare:('b -> 'a -> lem_basic_classes$ordering) -> 'b option -> 'a option -> lem_basic_classes$ordering) cmp (SOME x') (SOME y')=  (cmp x' y'))`;


val _ = Define `
((instance_Basic_classes_Ord_Maybe_maybe_dict:'a lem_basic_classes$Ord_class ->('a option)lem_basic_classes$Ord_class)dict_Basic_classes_Ord_a= (<|

  compare_method := (maybeCompare  
  dict_Basic_classes_Ord_a.compare_method);

  isLess_method := (\ m1 .  (\ m2 .  maybeCompare  
  dict_Basic_classes_Ord_a.compare_method m1 m2 = LT));

  isLessEqual_method := (\ m1 .  (\ m2 .  (let r = (maybeCompare  
  dict_Basic_classes_Ord_a.compare_method m1 m2) in (r = LT) \/ (r = EQ))));

  isGreater_method := (\ m1 .  (\ m2 .  maybeCompare  
  dict_Basic_classes_Ord_a.compare_method m1 m2 = GT));

  isGreaterEqual_method := (\ m1 .  (\ m2 .  (let r = (maybeCompare  
  dict_Basic_classes_Ord_a.compare_method m1 m2) in (r = GT) \/ (r = EQ))))|>))`;


(* ----------------------- *)
(* maybe                   *)
(* ----------------------- *)

(*val maybe : forall 'a 'b. 'b -> ('a -> 'b) -> maybe 'a -> 'b*)
(*let maybe d f mb=  match mb with 
  | Just a -> f a
  | Nothing -> d
end*)

(* ----------------------- *)
(* isJust / isNothing      *)
(* ----------------------- *)

(*val isJust : forall 'a. maybe 'a -> bool*)
(*let isJust mb=  match mb with 
  | Just _ -> true
  | Nothing -> false
end*)

(*val isNothing : forall 'a. maybe 'a -> bool*)
(*let isNothing mb=  match mb with 
  | Just _ -> false
  | Nothing -> true
end*)

(* ----------------------- *)
(* fromMaybe               *)
(* ----------------------- *)

(*val fromMaybe : forall 'a. 'a -> maybe 'a -> 'a*)
(*let fromMaybe d mb=  match mb with
   | Just v  -> v
   | Nothing -> d
end*)

(* ----------------------- *)
(* map                     *)
(* ----------------------- *)

(*val map : forall 'a 'b. ('a -> 'b) -> maybe 'a -> maybe 'b*) 
(*let map f=  maybe Nothing (fun v -> Just (f v))*)


(* ----------------------- *)
(* bind                    *)
(* ----------------------- *)

(*val bind : forall 'a 'b. maybe 'a -> ('a -> maybe 'b) -> maybe 'b*) 
(*let bind mb f=  maybe Nothing f mb*)
val _ = export_theory()

